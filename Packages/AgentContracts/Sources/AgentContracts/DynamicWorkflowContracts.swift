// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Script identity and metadata

/// The stable language/runtime ABI understood by a workflow script provider.
public enum WorkflowScriptABI {
    public static let v1 = try! SemanticVersion(major: 1, minor: 0, patch: 0)
}

/// One display phase declared by the leading workflow metadata literal.
public struct WorkflowPhaseMetadataV1: Hashable, Codable, Sendable {
    public let title: String
    public let detail: String?
    public let requestedModel: String?

    public init(title: String, detail: String? = nil, requestedModel: String? = nil) throws {
        guard AgentWireValidation.isNonblankControlFree(title, maximumLength: 256),
              detail.map({
                  $0.isEmpty || AgentWireValidation.isNonblankControlFree($0, maximumLength: 2_048)
              }) ?? true,
              requestedModel.map({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 256)
              }) ?? true
        else { throw AgentContractError.invalidName("workflow phase metadata") }
        self.title = title
        self.detail = detail
        self.requestedModel = requestedModel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                title: values.decode(String.self, forKey: .title),
                detail: values.decodeIfPresent(String.self, forKey: .detail),
                requestedModel: values.decodeIfPresent(String.self, forKey: .requestedModel)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)
            ))
        }
    }
}

/// Statically extracted pure-literal metadata from the first script statement.
public struct WorkflowScriptMetadataV1: Hashable, Codable, Sendable {
    public let name: String
    public let description: String
    public let whenToUse: String?
    public let phases: [WorkflowPhaseMetadataV1]

    public init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        phases: [WorkflowPhaseMetadataV1] = []
    ) throws {
        guard Self.validWorkflowName(name),
              AgentWireValidation.isNonblankControlFree(description, maximumLength: 4_096),
              whenToUse.map({
                  $0.isEmpty || AgentWireValidation.isNonblankControlFree($0, maximumLength: 4_096)
              }) ?? true,
              phases.count <= 128
        else { throw AgentContractError.invalidName("workflow metadata") }
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.phases = phases
    }

    private static func validWorkflowName(_ value: String) -> Bool {
        guard (1 ... 41).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              (0x61 ... 0x7A).contains(first.value)
        else { return false }
        return value.unicodeScalars.allSatisfy {
            (0x61 ... 0x7A).contains($0.value)
                || (0x30 ... 0x39).contains($0.value)
                || $0.value == 0x2D
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                name: values.decode(String.self, forKey: .name),
                description: values.decode(String.self, forKey: .description),
                whenToUse: values.decodeIfPresent(String.self, forKey: .whenToUse),
                phases: values.decode([WorkflowPhaseMetadataV1].self, forKey: .phases)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)
            ))
        }
    }
}

/// Immutable normalized source for one Claude-style JavaScript workflow.
public struct WorkflowScriptV1: Hashable, Codable, Sendable {
    public static let maximumSourceBytes = 1_048_576

    public let scriptID: WorkflowScriptID
    public let version: UInt64
    public let abiVersion: SemanticVersion
    public let source: String
    public let sourceDigest: StableDigest

    public init(
        scriptID: WorkflowScriptID,
        version: UInt64,
        source: String,
        abiVersion: SemanticVersion = WorkflowScriptABI.v1
    ) throws {
        guard version > 0, abiVersion.major == WorkflowScriptABI.v1.major else {
            throw AgentContractError.invalidName("workflow script version")
        }
        let normalized = Self.normalize(source)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }),
              normalized.lengthOfBytes(using: .utf8) <= Self.maximumSourceBytes
        else { throw AgentContractError.invalidName("workflow script source") }
        self.scriptID = scriptID
        self.version = version
        self.abiVersion = abiVersion
        self.source = normalized
        sourceDigest = StableDigest.fingerprint(
            domain: "dynamic-workflow-script.v1",
            components: [Data(abiVersion.description.utf8), Data(normalized.utf8)]
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDigest = try values.decode(StableDigest.self, forKey: .sourceDigest)
        do {
            try self.init(
                scriptID: values.decode(WorkflowScriptID.self, forKey: .scriptID),
                version: values.decode(UInt64.self, forKey: .version),
                source: values.decode(String.self, forKey: .source),
                abiVersion: values.decode(SemanticVersion.self, forKey: .abiVersion)
            )
            guard sourceDigest == encodedDigest else {
                throw AgentContractError.invalidDigest(encodedDigest.rawValue)
            }
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case scriptID, version, abiVersion, source, sourceDigest
    }

    private static func normalize(_ source: String) -> String {
        var value = source
        if value.unicodeScalars.first?.value == 0xFEFF { value.removeFirst() }
        return value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    public var reference: WorkflowScriptReferenceV1 {
        WorkflowScriptReferenceV1(
            scriptID: scriptID,
            version: version,
            abiVersion: abiVersion,
            sourceDigest: sourceDigest
        )
    }
}

/// Small durable reference to content-addressed source stored outside run events.
public struct WorkflowScriptReferenceV1: Hashable, Codable, Sendable {
    public let scriptID: WorkflowScriptID
    public let version: UInt64
    public let abiVersion: SemanticVersion
    public let sourceDigest: StableDigest

    public init(
        scriptID: WorkflowScriptID,
        version: UInt64,
        abiVersion: SemanticVersion,
        sourceDigest: StableDigest
    ) {
        self.scriptID = scriptID
        self.version = version
        self.abiVersion = abiVersion
        self.sourceDigest = sourceDigest
    }
}

/// Where a reusable workflow script is visible. Scope never grants execution authority.
public enum WorkflowScriptScopeV1: String, CaseIterable, Hashable, Codable, Sendable {
    case conversation
    case project
    case personal
    case bundled
}

/// Exact catalog owner for a reusable script. Visibility is never inferred from a broad scope:
/// conversation and personal entries are resolved only through an owner explicitly frozen into
/// the launch snapshot. The opaque digests let an app bind personal/project/bundled catalogs to
/// its own durable identity without exposing account data to scripts.
public enum WorkflowScriptOwnerV1: Hashable, Codable, Sendable {
    case conversation(ConversationID)
    case personal(StableDigest)
    case project(StableDigest)
    case bundled(StableDigest)

    public var scope: WorkflowScriptScopeV1 {
        switch self {
        case .conversation: .conversation
        case .personal: .personal
        case .project: .project
        case .bundled: .bundled
        }
    }

    public var storageKey: String {
        switch self {
        case .conversation(let id): "conversation:\(id.description)"
        case .personal(let digest): "personal:\(digest.rawValue)"
        case .project(let digest): "project:\(digest.rawValue)"
        case .bundled(let digest): "bundled:\(digest.rawValue)"
        }
    }
}

/// Append-only saved-script catalog entry pinned to one immutable source digest.
public struct SavedWorkflowScriptV1: Hashable, Codable, Sendable {
    public let script: WorkflowScriptV1
    public let metadata: WorkflowScriptMetadataV1
    public let owner: WorkflowScriptOwnerV1
    public let createdAt: AgentTimestamp

    public var scope: WorkflowScriptScopeV1 { owner.scope }

    public init(
        script: WorkflowScriptV1,
        metadata: WorkflowScriptMetadataV1,
        owner: WorkflowScriptOwnerV1,
        createdAt: AgentTimestamp
    ) {
        self.script = script
        self.metadata = metadata
        self.owner = owner
        self.createdAt = createdAt
    }
}

// MARK: - Limits and runtime negotiation

/// Trusted hard limits frozen before one workflow starts.
public struct WorkflowRunLimitsV1: Hashable, Codable, Sendable {
    public static let hardMaximumConcurrentAgents: UInt16 = 16
    public static let hardMaximumAgentCalls: UInt32 = 1_000
    public static let hardMaximumCollectionItems: UInt32 = 4_096
    public static let hardMaximumWallClockMilliseconds: UInt64 = 24 * 60 * 60 * 1_000
    public static let hardMaximumScriptSteps: UInt64 = 50_000_000
    public static let hardMaximumLines: UInt32 = 10_000
    /// The ABI transports values as `CanonicalJSON`, whose contract-level hard limit is 8 MiB.
    public static let hardMaximumSerializedValueBytes: UInt64 = UInt64(CanonicalJSON.maximumBytes)

    public let maximumConcurrentAgents: UInt16
    public let maximumAgentCalls: UInt32
    public let maximumCollectionItems: UInt32
    public let maximumWallClockMilliseconds: UInt64
    public let maximumScriptSteps: UInt64
    public let maximumLogLines: UInt32
    public let maximumPhaseEntries: UInt32
    public let maximumSerializedValueBytes: UInt64
    public let schemaRepairAttempts: UInt8
    public let maximumNestedWorkflowDepth: UInt8

    public init(
        maximumConcurrentAgents: UInt16,
        maximumAgentCalls: UInt32 = hardMaximumAgentCalls,
        maximumCollectionItems: UInt32 = hardMaximumCollectionItems,
        maximumWallClockMilliseconds: UInt64 = 30 * 60 * 1_000,
        maximumScriptSteps: UInt64 = 5_000_000,
        maximumLogLines: UInt32 = hardMaximumLines,
        maximumPhaseEntries: UInt32 = hardMaximumLines,
        maximumSerializedValueBytes: UInt64 = UInt64(CanonicalJSON.maximumBytes),
        schemaRepairAttempts: UInt8 = 2,
        maximumNestedWorkflowDepth: UInt8 = 1
    ) throws {
        guard maximumConcurrentAgents > 0,
              maximumConcurrentAgents <= Self.hardMaximumConcurrentAgents,
              maximumAgentCalls > 0, maximumAgentCalls <= Self.hardMaximumAgentCalls,
              maximumCollectionItems > 0,
              maximumCollectionItems <= Self.hardMaximumCollectionItems,
              maximumWallClockMilliseconds > 0,
              maximumWallClockMilliseconds <= Self.hardMaximumWallClockMilliseconds,
              maximumScriptSteps > 0, maximumScriptSteps <= Self.hardMaximumScriptSteps,
              maximumLogLines > 0, maximumLogLines <= Self.hardMaximumLines,
              maximumPhaseEntries > 0, maximumPhaseEntries <= Self.hardMaximumLines,
              maximumSerializedValueBytes > 0,
              maximumSerializedValueBytes <= Self.hardMaximumSerializedValueBytes,
              schemaRepairAttempts <= 2,
              maximumNestedWorkflowDepth <= 1
        else { throw AgentContractError.invalidName("workflow run limits") }
        self.maximumConcurrentAgents = maximumConcurrentAgents
        self.maximumAgentCalls = maximumAgentCalls
        self.maximumCollectionItems = maximumCollectionItems
        self.maximumWallClockMilliseconds = maximumWallClockMilliseconds
        self.maximumScriptSteps = maximumScriptSteps
        self.maximumLogLines = maximumLogLines
        self.maximumPhaseEntries = maximumPhaseEntries
        self.maximumSerializedValueBytes = maximumSerializedValueBytes
        self.schemaRepairAttempts = schemaRepairAttempts
        self.maximumNestedWorkflowDepth = maximumNestedWorkflowDepth
    }

    public static func iPhoneDefault(processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Self {
        let suggested = max(1, min(4, processorCount - 2))
        return try! Self(maximumConcurrentAgents: UInt16(suggested))
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumConcurrentAgents: values.decode(UInt16.self, forKey: .maximumConcurrentAgents),
                maximumAgentCalls: values.decode(UInt32.self, forKey: .maximumAgentCalls),
                maximumCollectionItems: values.decode(UInt32.self, forKey: .maximumCollectionItems),
                maximumWallClockMilliseconds: values.decode(UInt64.self, forKey: .maximumWallClockMilliseconds),
                maximumScriptSteps: values.decode(UInt64.self, forKey: .maximumScriptSteps),
                maximumLogLines: values.decode(UInt32.self, forKey: .maximumLogLines),
                maximumPhaseEntries: values.decode(UInt32.self, forKey: .maximumPhaseEntries),
                maximumSerializedValueBytes: values.decode(UInt64.self, forKey: .maximumSerializedValueBytes),
                schemaRepairAttempts: values.decode(UInt8.self, forKey: .schemaRepairAttempts),
                maximumNestedWorkflowDepth: values.decode(UInt8.self, forKey: .maximumNestedWorkflowDepth)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)
            ))
        }
    }
}

/// Isolation guarantees a script runtime can truthfully advertise.
public enum WorkflowRuntimeIsolationV1: UInt8, CaseIterable, Hashable, Codable, Sendable, Comparable {
    case logicalRealm = 0
    case isolatedWorker = 1
    case hardenedSandbox = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Requirements negotiated independently from an agent's optional execution sandbox.
public struct WorkflowRuntimeRequirementV1: Hashable, Codable, Sendable {
    public let minimumABIVersion: SemanticVersion
    public let minimumIsolation: WorkflowRuntimeIsolationV1
    public let requiresHardMemoryLimit: Bool
    public let requiresPreemptiveTermination: Bool

    public init(
        minimumABIVersion: SemanticVersion = WorkflowScriptABI.v1,
        minimumIsolation: WorkflowRuntimeIsolationV1 = .logicalRealm,
        requiresHardMemoryLimit: Bool = false,
        requiresPreemptiveTermination: Bool = false
    ) {
        self.minimumABIVersion = minimumABIVersion
        self.minimumIsolation = minimumIsolation
        self.requiresHardMemoryLimit = requiresHardMemoryLimit
        self.requiresPreemptiveTermination = requiresPreemptiveTermination
    }
}

/// Capabilities advertised by one injected script runtime provider.
public struct WorkflowRuntimeCapabilitiesV1: Hashable, Codable, Sendable {
    public let providerID: String
    public let abiVersions: [SemanticVersion]
    public let isolation: WorkflowRuntimeIsolationV1
    public let hasHardMemoryLimit: Bool
    public let hasPreemptiveTermination: Bool

    public init(
        providerID: String,
        abiVersions: [SemanticVersion],
        isolation: WorkflowRuntimeIsolationV1,
        hasHardMemoryLimit: Bool,
        hasPreemptiveTermination: Bool
    ) throws {
        let versions = Array(Set(abiVersions)).sorted()
        guard AgentWireValidation.isLowercaseNamespace(providerID, maximumLength: 128),
              !versions.isEmpty
        else { throw AgentContractError.invalidName("workflow runtime capabilities") }
        self.providerID = providerID
        self.abiVersions = versions
        self.isolation = isolation
        self.hasHardMemoryLimit = hasHardMemoryLimit
        self.hasPreemptiveTermination = hasPreemptiveTermination
    }

    public func satisfies(_ requirement: WorkflowRuntimeRequirementV1) -> Bool {
        abiVersions.contains { $0.major == requirement.minimumABIVersion.major && $0 >= requirement.minimumABIVersion }
            && isolation >= requirement.minimumIsolation
            && (!requirement.requiresHardMemoryLimit || hasHardMemoryLimit)
            && (!requirement.requiresPreemptiveTermination || hasPreemptiveTermination)
    }
}

// MARK: - Launch snapshot and agent calls

/// Immutable workflow launch inputs and inherited authority.
public struct WorkflowLaunchSnapshotV1: Hashable, Codable, Sendable {
    public let runID: WorkflowRunID
    public let scriptReference: WorkflowScriptReferenceV1
    public let args: CanonicalJSON?
    public let conversationID: ConversationID
    public let initiatingRunID: AgentRunID
    public let initiatingRequestID: AgentRequestID
    public let requestingStepID: AgentStepID
    public let capabilityCeiling: RunCapabilityCeiling
    public let budget: AgentBudget
    public let defaultModelPolicy: AgentModelPolicy
    public let toolPolicyDigest: StableDigest
    public let policySnapshotDigest: StableDigest
    public let runtimeRequirement: WorkflowRuntimeRequirementV1
    public let limits: WorkflowRunLimitsV1
    public let approvalMode: AgentApprovalMode
    /// Ordered catalog visibility, most specific first. The default is this conversation only.
    public let savedWorkflowOwners: [WorkflowScriptOwnerV1]
    /// Direct dependencies resolved before launch approval. Runtime execution may use only these
    /// immutable references and never performs a mutable catalog name lookup.
    public let savedWorkflowPins: [String: WorkflowScriptReferenceV1]

    public init(
        runID: WorkflowRunID,
        scriptReference: WorkflowScriptReferenceV1,
        args: CanonicalJSON?,
        conversationID: ConversationID,
        initiatingRunID: AgentRunID,
        initiatingRequestID: AgentRequestID,
        requestingStepID: AgentStepID,
        capabilityCeiling: RunCapabilityCeiling,
        budget: AgentBudget,
        defaultModelPolicy: AgentModelPolicy,
        toolPolicyDigest: StableDigest,
        policySnapshotDigest: StableDigest,
        runtimeRequirement: WorkflowRuntimeRequirementV1 = .init(),
        limits: WorkflowRunLimitsV1 = .iPhoneDefault(),
        approvalMode: AgentApprovalMode = .ask,
        savedWorkflowOwners: [WorkflowScriptOwnerV1]? = nil,
        savedWorkflowPins: [String: WorkflowScriptReferenceV1] = [:]
    ) {
        self.runID = runID
        self.scriptReference = scriptReference
        self.args = args
        self.conversationID = conversationID
        self.initiatingRunID = initiatingRunID
        self.initiatingRequestID = initiatingRequestID
        self.requestingStepID = requestingStepID
        self.capabilityCeiling = capabilityCeiling
        self.budget = budget
        self.defaultModelPolicy = defaultModelPolicy
        self.toolPolicyDigest = toolPolicyDigest
        self.policySnapshotDigest = policySnapshotDigest
        self.runtimeRequirement = runtimeRequirement
        self.limits = limits
        self.approvalMode = approvalMode
        let owners = savedWorkflowOwners ?? [.conversation(conversationID)]
        self.savedWorkflowOwners = owners.reduce(into: []) { result, owner in
            if !result.contains(owner) { result.append(owner) }
        }
        self.savedWorkflowPins = savedWorkflowPins
    }

    public func pinningSavedWorkflows(
        _ pins: [String: WorkflowScriptReferenceV1]
    ) -> WorkflowLaunchSnapshotV1 {
        WorkflowLaunchSnapshotV1(
            runID: runID,
            scriptReference: scriptReference,
            args: args,
            conversationID: conversationID,
            initiatingRunID: initiatingRunID,
            initiatingRequestID: initiatingRequestID,
            requestingStepID: requestingStepID,
            capabilityCeiling: capabilityCeiling,
            budget: budget,
            defaultModelPolicy: defaultModelPolicy,
            toolPolicyDigest: toolPolicyDigest,
            policySnapshotDigest: policySnapshotDigest,
            runtimeRequirement: runtimeRequirement,
            limits: limits,
            approvalMode: approvalMode,
            savedWorkflowOwners: savedWorkflowOwners,
            savedWorkflowPins: pins
        )
    }
}

/// Reusable launch consent. It never grants any child tool or external-operation authority.
public enum WorkflowLaunchApprovalReuseScopeV1: String, Hashable, Codable, Sendable {
    case conversation
    case personal
}

public struct WorkflowLaunchApprovalV1: Hashable, Codable, Sendable {
    public let approvalID: ApprovalID
    public let scriptReference: WorkflowScriptReferenceV1
    public let reuseScope: WorkflowLaunchApprovalReuseScopeV1
    public let conversationID: ConversationID?
    public let authorizationDigest: StableDigest
    public let createdAt: AgentTimestamp

    public init(
        approvalID: ApprovalID,
        launch: WorkflowLaunchSnapshotV1,
        reuseScope: WorkflowLaunchApprovalReuseScopeV1,
        createdAt: AgentTimestamp
    ) throws {
        self.approvalID = approvalID
        scriptReference = launch.scriptReference
        self.reuseScope = reuseScope
        conversationID = reuseScope == .conversation ? launch.conversationID : nil
        authorizationDigest = try Self.authorizationDigest(for: launch)
        self.createdAt = createdAt
    }

    public func authorizes(_ launch: WorkflowLaunchSnapshotV1) throws -> Bool {
        let expectedAuthorizationDigest = try Self.authorizationDigest(for: launch)
        return scriptReference == launch.scriptReference
            && authorizationDigest == expectedAuthorizationDigest
            && (reuseScope == .personal || conversationID == launch.conversationID)
    }

    private static func authorizationDigest(
        for launch: WorkflowLaunchSnapshotV1
    ) throws -> StableDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return StableDigest.fingerprint(
            domain: "dynamic-workflow-launch-authorization.v1",
            components: [
                Data(launch.scriptReference.sourceDigest.rawValue.utf8),
                Data(launch.capabilityCeiling.fingerprint.rawValue.utf8),
                try encoder.encode(launch.budget),
                try encoder.encode(launch.savedWorkflowOwners),
                try encoder.encode(launch.savedWorkflowPins),
                Data(launch.toolPolicyDigest.rawValue.utf8),
                Data(launch.policySnapshotDigest.rawValue.utf8),
                try encoder.encode(launch.defaultModelPolicy),
                try encoder.encode(launch.runtimeRequirement),
                try encoder.encode(launch.limits),
                try encoder.encode(launch.approvalMode),
            ]
        )
    }
}

/// Output-affecting options accepted by the `agent()` primitive.
public struct WorkflowAgentOptionsV1: Hashable, Codable, Sendable {
    public let label: String?
    public let phase: String?
    public let schema: JSONSchemaDocument?
    public let requestedModel: String?
    public let requestedAgentType: String?
    public let requiresIsolatedWorkspace: Bool
    public let stallMilliseconds: UInt64?
    /// Optional per-child tool-call ceiling. It can only narrow the host's available budget.
    public let maximumToolCalls: UInt64?
    public let task: WorkflowTaskDescriptorV1?
    /// Stable agent identity inside this workflow, independent of its current task or activation.
    public let sessionKey: String?
    public let profile: WorkflowAgentProfileV1?

    public init(
        label: String? = nil,
        phase: String? = nil,
        schema: JSONSchemaDocument? = nil,
        requestedModel: String? = nil,
        requestedAgentType: String? = nil,
        requiresIsolatedWorkspace: Bool = false,
        stallMilliseconds: UInt64? = nil,
        maximumToolCalls: UInt64? = nil,
        task: WorkflowTaskDescriptorV1? = nil,
        sessionKey: String? = nil,
        profile: WorkflowAgentProfileV1? = nil
    ) throws {
        guard label.map({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 256)
              }) ?? true,
              phase.map({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 256)
              }) ?? true,
              requestedModel.map({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 256)
              }) ?? true,
              requestedAgentType.map({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 128)
              }) ?? true,
              schema.map({ $0.enforcement == .fullyEnforced }) ?? true,
              stallMilliseconds.map({ $0 <= 30 * 60 * 1_000 }) ?? true,
              maximumToolCalls.map({ $0 <= 1_000 }) ?? true,
              sessionKey.map({ AgentWireValidation.isNonblankControlFree($0, maximumLength: 128) }) ?? true
        else { throw AgentContractError.invalidName("workflow agent options") }
        self.label = label
        self.phase = phase
        self.schema = schema
        self.requestedModel = requestedModel
        self.requestedAgentType = requestedAgentType
        self.requiresIsolatedWorkspace = requiresIsolatedWorkspace
        self.stallMilliseconds = stallMilliseconds
        self.maximumToolCalls = maximumToolCalls
        self.task = task
        self.sessionKey = sessionKey
        self.profile = profile
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                label: values.decodeIfPresent(String.self, forKey: .label),
                phase: values.decodeIfPresent(String.self, forKey: .phase),
                schema: values.decodeIfPresent(JSONSchemaDocument.self, forKey: .schema),
                requestedModel: values.decodeIfPresent(String.self, forKey: .requestedModel),
                requestedAgentType: values.decodeIfPresent(String.self, forKey: .requestedAgentType),
                requiresIsolatedWorkspace: values.decode(Bool.self, forKey: .requiresIsolatedWorkspace),
                stallMilliseconds: values.decodeIfPresent(UInt64.self, forKey: .stallMilliseconds),
                maximumToolCalls: values.decodeIfPresent(UInt64.self, forKey: .maximumToolCalls),
                task: values.decodeIfPresent(WorkflowTaskDescriptorV1.self, forKey: .task),
                sessionKey: values.decodeIfPresent(String.self, forKey: .sessionKey),
                profile: values.decodeIfPresent(WorkflowAgentProfileV1.self, forKey: .profile)
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)
            ))
        }
    }

    /// Canonical identity excludes display/operational fields, matching prefix-resume semantics.
    public func outputIdentity() throws -> StableDigest {
        var object: [String: JSONValue] = [
            "requiresIsolatedWorkspace": .bool(requiresIsolatedWorkspace)
        ]
        if let schema { object["schemaDigest"] = .string(schema.digest.rawValue) }
        if let requestedModel { object["requestedModel"] = .string(requestedModel) }
        if let requestedAgentType { object["requestedAgentType"] = .string(requestedAgentType) }
        if let maximumToolCalls { object["maximumToolCalls"] = .unsignedInteger(maximumToolCalls) }
        if let sessionKey { object["sessionKey"] = .string(sessionKey) }
        if let profile { object["profileDigest"] = .string(profile.digest.rawValue) }
        if let task, let revision = task.expectedRevision {
            object["taskClaim"] = .object(["id": .string(task.taskID), "revision": .unsignedInteger(revision),
                "inputs": .array(task.inputArtifactIDs.map(JSONValue.string)), "output": .string(task.outputArtifactID)])
        }
        return try CanonicalJSON(.object(object)).fingerprint
    }
}

/// Started-order identity of one workflow `agent()` invocation.
public struct WorkflowAgentCallV1: Hashable, Codable, Sendable {
    public let callID: WorkflowAgentCallID
    public let ordinal: UInt32
    public let attempt: UInt16
    public let prefixKey: StableDigest
    public let promptDigest: StableDigest
    public let options: WorkflowAgentOptionsV1
    public let childRunID: AgentRunID

    public init(
        callID: WorkflowAgentCallID,
        ordinal: UInt32,
        attempt: UInt16 = 1,
        prefixKey: StableDigest,
        promptDigest: StableDigest,
        options: WorkflowAgentOptionsV1,
        childRunID: AgentRunID
    ) throws {
        guard ordinal > 0, attempt > 0 else {
            throw AgentContractError.invalidEventSequence("workflow call identity")
        }
        self.callID = callID
        self.ordinal = ordinal
        self.attempt = attempt
        self.prefixKey = prefixKey
        self.promptDigest = promptDigest
        self.options = options
        self.childRunID = childRunID
    }
}

/// Bounded workflow value, either inline canonical JSON or a content-addressed artifact.
public enum WorkflowValueReferenceV1: Hashable, Codable, Sendable {
    case inline(CanonicalJSON)
    case artifact(ArtifactReference)
}

/// Settled result of one agent invocation. Structural failures terminate the workflow separately.
public enum WorkflowAgentOutcomeV1: Hashable, Codable, Sendable {
    case completed(value: WorkflowValueReferenceV1, usage: AgentUsage)
    case unavailable(reason: String, usage: AgentUsage)
    /// A durable typed child failure that must fail orchestration when replayed or bridged.
    case failed(failure: AgentFailure, usage: AgentUsage)
    case stopped(usage: AgentUsage)
}

// MARK: - Durable workflow lifecycle

public enum WorkflowRunStateV1: String, CaseIterable, Hashable, Codable, Sendable {
    case waitingForLaunchApproval
    case queued
    case running
    case pausing
    case paused
    case waitingForForeground
    case waitingForReconciliation
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public enum WorkflowRunControlV1: Hashable, Codable, Sendable {
    case pause
    case resume
    case stop
    case restartAgent(WorkflowAgentCallID)
    case reconcileAgent(WorkflowAgentCallID, AgentReconciliationDecision)
}

public enum WorkflowRunEventKindV1: Hashable, Codable, Sendable {
    case created(WorkflowLaunchSnapshotV1)
    case preparationUsageCommitted(AgentUsage)
    case launchApproved(ApprovalID)
    case stateChanged(from: WorkflowRunStateV1, to: WorkflowRunStateV1, reason: String?)
    case phaseStarted(String)
    case logAppended(String)
    case savedWorkflowPinned(name: String, reference: WorkflowScriptReferenceV1)
    case agentCallPrepared(WorkflowAgentCallV1)
    case agentChildSubmitted(callID: WorkflowAgentCallID, handleID: AgentExecutionHandleID)
    case agentCallSettled(callID: WorkflowAgentCallID, outcome: WorkflowAgentOutcomeV1)
    case waitSelected(WorkflowWaitSelection)
    case collaborationRecorded(WorkflowCollaborationReceipt)
    case goalAmended(WorkflowGoalAmendment)
    case goalResumed(pauseIndex: UInt32, graph: WorkflowTaskGraph)
    case agentRestartRequested(callID: WorkflowAgentCallID)
    case usageCommitted(AgentUsage)
    case reconciliationRequired(callID: WorkflowAgentCallID?, reason: String)
    /// Durable write-ahead intent. The child command must not be issued before this event commits.
    case reconciliationRequested(callID: WorkflowAgentCallID, decision: AgentReconciliationDecision)
    case reconciliationDecided(callID: WorkflowAgentCallID, decision: AgentReconciliationDecision)
    case outputCommitted(WorkflowValueReferenceV1)
    case failureCommitted(String)
}

/// Hash-chained event for one durable workflow run.
public struct WorkflowRunEventV1: Hashable, Codable, Sendable {
    public let eventID: WorkflowEventID
    public let runID: WorkflowRunID
    public let sequence: UInt64
    public let timestamp: AgentTimestamp
    public let previousDigest: StableDigest?
    public let kind: WorkflowRunEventKindV1
    public let recordDigest: StableDigest

    public init(
        eventID: WorkflowEventID,
        runID: WorkflowRunID,
        sequence: UInt64,
        timestamp: AgentTimestamp,
        previousDigest: StableDigest?,
        kind: WorkflowRunEventKindV1
    ) throws {
        guard sequence > 0, (sequence == 1) == (previousDigest == nil) else {
            throw AgentContractError.invalidEventSequence("workflow event chain")
        }
        self.eventID = eventID
        self.runID = runID
        self.sequence = sequence
        self.timestamp = timestamp
        self.previousDigest = previousDigest
        self.kind = kind
        recordDigest = try Self.digest(
            eventID: eventID,
            runID: runID,
            sequence: sequence,
            timestamp: timestamp,
            previousDigest: previousDigest,
            kind: kind
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDigest = try values.decode(StableDigest.self, forKey: .recordDigest)
        do {
            try self.init(
                eventID: values.decode(WorkflowEventID.self, forKey: .eventID),
                runID: values.decode(WorkflowRunID.self, forKey: .runID),
                sequence: values.decode(UInt64.self, forKey: .sequence),
                timestamp: values.decode(AgentTimestamp.self, forKey: .timestamp),
                previousDigest: values.decodeIfPresent(StableDigest.self, forKey: .previousDigest),
                kind: values.decode(WorkflowRunEventKindV1.self, forKey: .kind)
            )
            guard recordDigest == encodedDigest else {
                throw AgentContractError.invalidDigest(encodedDigest.rawValue)
            }
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: String(describing: error)
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, runID, sequence, timestamp, previousDigest, kind, recordDigest
    }

    private static func digest(
        eventID: WorkflowEventID,
        runID: WorkflowRunID,
        sequence: UInt64,
        timestamp: AgentTimestamp,
        previousDigest: StableDigest?,
        kind: WorkflowRunEventKindV1
    ) throws -> StableDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return StableDigest.fingerprint(
            domain: "dynamic-workflow-event.v1",
            components: [
                Data(eventID.description.utf8),
                Data(runID.description.utf8),
                Data(String(sequence).utf8),
                Data(String(timestamp.rawValue).utf8),
                Data((previousDigest?.rawValue ?? "").utf8),
                try encoder.encode(kind),
            ]
        )
    }
}

/// Compare-and-swap append used by durable workflow journals.
public struct WorkflowEventAppendRequestV1: Hashable, Codable, Sendable {
    public let runID: WorkflowRunID
    public let expectedSequence: UInt64
    public let expectedDigest: StableDigest?
    public let events: [WorkflowRunEventV1]

    public init(
        runID: WorkflowRunID,
        expectedSequence: UInt64,
        expectedDigest: StableDigest?,
        events: [WorkflowRunEventV1]
    ) throws {
        guard !events.isEmpty,
              (expectedSequence == 0) == (expectedDigest == nil),
              events.first?.sequence == expectedSequence + 1,
              events.last?.sequence == expectedSequence + UInt64(events.count),
              events.allSatisfy({ $0.runID == runID })
        else { throw AgentContractError.invalidEventSequence("workflow append request") }
        var previous = expectedDigest
        for event in events {
            guard event.previousDigest == previous else {
                throw AgentContractError.invalidEventSequence("workflow append hash chain")
            }
            previous = event.recordDigest
        }
        self.runID = runID
        self.expectedSequence = expectedSequence
        self.expectedDigest = expectedDigest
        self.events = events
    }
}
