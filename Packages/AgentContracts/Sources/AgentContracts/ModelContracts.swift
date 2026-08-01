// SPDX-License-Identifier: MIT

import Foundation

/// A marker protocol giving each stable string identifier a compile-time domain.
public protocol AgentNamedIdentifierDomain: Sendable {}

/// A bounded, control-free stable string identifier with a non-interchangeable domain.
public struct AgentNamedIdentifier<Domain: AgentNamedIdentifierDomain>: Hashable, Codable, Sendable,
    Comparable, CustomStringConvertible
{
    /// Stable adapter-defined identifier.
    public let rawValue: String

    /// Creates a validated stable string identifier.
    public init(_ rawValue: String) throws {
        guard AgentWireValidation.isNonblankControlFree(rawValue, maximumLength: 256) else {
            throw AgentContractError.invalidName("named identifier")
        }
        self.rawValue = rawValue
    }

    /// Stable wire representation.
    public var description: String { rawValue }

    /// Orders identifiers by their stable representation.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Decodes one validated stable string identifier.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(container.decode(String.self)) }
        catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    /// Encodes one stable string identifier.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Named-identifier domain for a model provider.
public enum AgentModelProviderIDDomain: AgentNamedIdentifierDomain {}
/// Named-identifier domain for a model family or repository.
public enum AgentModelIDDomain: AgentNamedIdentifierDomain {}
/// Named-identifier domain for an exact model variant.
public enum AgentModelVariantIDDomain: AgentNamedIdentifierDomain {}

/// Stable model-provider identity.
public typealias AgentModelProviderID = AgentNamedIdentifier<AgentModelProviderIDDomain>
/// Stable model identity within a provider.
public typealias AgentModelID = AgentNamedIdentifier<AgentModelIDDomain>
/// Stable exact model-variant identity.
public typealias AgentModelVariantID = AgentNamedIdentifier<AgentModelVariantIDDomain>

/// One exact provider/model/variant selection pinned for a run.
public struct AgentModelSelection: Hashable, Codable, Sendable, Comparable {
    /// Provider selected for the run.
    public let providerID: AgentModelProviderID
    /// Model selected for the run.
    public let modelID: AgentModelID
    /// Exact variant selected for the run.
    public let variantID: AgentModelVariantID
    /// Provider capability revision pinned for recovery.
    public let capabilityVersion: SemanticVersion

    /// Creates an exact pinned model selection.
    public init(
        providerID: AgentModelProviderID,
        modelID: AgentModelID,
        variantID: AgentModelVariantID,
        capabilityVersion: SemanticVersion
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.variantID = variantID
        self.capabilityVersion = capabilityVersion
    }

    /// Orders selections by stable provider, model, variant, and capability revision.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.providerID != rhs.providerID { return lhs.providerID < rhs.providerID }
        if lhs.modelID != rhs.modelID { return lhs.modelID < rhs.modelID }
        if lhs.variantID != rhs.variantID { return lhs.variantID < rhs.variantID }
        return lhs.capabilityVersion < rhs.capabilityVersion
    }
}

/// Model selection strategy understood by runtime policy rather than a concrete engine.
public enum AgentModelSelectionStrategy: String, CaseIterable, Hashable, Codable, Sendable {
    /// Use exactly one pinned selection.
    case pinned
    /// Choose deterministically within the supplied local-only candidates.
    case deterministicLocalPolicy
}

/// Provider-neutral model policy frozen into an agent request.
public struct AgentModelPolicy: Hashable, Codable, Sendable {
    /// Whether a provider that may transmit data is categorically forbidden.
    public let localOnly: Bool
    /// Allowed exact selections in deterministic preference order.
    public let allowedSelections: [AgentModelSelection]
    /// Selection strategy.
    public let strategy: AgentModelSelectionStrategy
    /// Required model capabilities.
    public let requiredCapabilities: AgentModelCapabilitySet

    /// Creates a nonempty deterministic model policy.
    public init(
        localOnly: Bool,
        allowedSelections: [AgentModelSelection],
        strategy: AgentModelSelectionStrategy,
        requiredCapabilities: AgentModelCapabilitySet
    ) throws {
        guard !allowedSelections.isEmpty,
              Set(allowedSelections).count == allowedSelections.count,
              strategy != .pinned || allowedSelections.count == 1
        else { throw AgentContractError.invalidName("model policy") }
        self.localOnly = localOnly
        self.allowedSelections = allowedSelections
        self.strategy = strategy
        self.requiredCapabilities = requiredCapabilities
    }

    /// Decodes and revalidates model-selection invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                localOnly: container.decode(Bool.self, forKey: .localOnly),
                allowedSelections: container.decode([AgentModelSelection].self, forKey: .allowedSelections),
                strategy: container.decode(AgentModelSelectionStrategy.self, forKey: .strategy),
                requiredCapabilities: container.decode(
                    AgentModelCapabilitySet.self,
                    forKey: .requiredCapabilities
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case localOnly, allowedSelections, strategy, requiredCapabilities
    }
}

/// A feature the runtime may require from a selected model provider.
public enum AgentModelCapability: String, CaseIterable, Hashable, Codable, Sendable, Comparable {
    /// Model emits separate reasoning deltas.
    case reasoning
    /// Model can consume image artifacts.
    case vision
    /// Model supports text-dialect tool calls.
    case textToolDialect
    /// Model supports native structured tool calls.
    case nativeToolCalling
    /// Model can return more than one tool call per pass.
    case multipleToolCalls
    /// Model supports JSON-schema constrained output.
    case jsonSchemaConstraint
    /// Model supports grammar-constrained output.
    case grammarConstraint
    /// Orders capabilities by stable wire identity.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Deterministic set of required or supported model capabilities.
public struct AgentModelCapabilitySet: Hashable, Codable, Sendable {
    /// Capabilities in stable order.
    public let values: [AgentModelCapability]

    /// Creates a normalized model-capability set.
    public init(_ values: some Sequence<AgentModelCapability>) {
        self.values = Array(Set(values)).sorted()
    }

    /// Returns whether one model capability is present.
    public func contains(_ capability: AgentModelCapability) -> Bool { values.contains(capability) }

    /// Decodes and rejects duplicate or noncanonical capability order.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode([AgentModelCapability].self)
        self.init(encoded)
        guard values == encoded else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Noncanonical model capability set"
            )
        }
    }

    /// Encodes a stable capability array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Tool-call transport exposed by a model provider.
public enum ModelToolCallingMode: String, CaseIterable, Hashable, Codable, Sendable {
    /// Model emits tool syntax in text that an adapter normalizes.
    case textDialect
    /// Provider emits native structured tool calls.
    case nativeStructured
    /// Provider does not support tools.
    case unavailable
}

/// Granularity at which a model attempt honors cancellation.
public enum ModelCancellationGranularity: String, CaseIterable, Hashable, Codable, Sendable {
    /// Cancellation may take effect between generated tokens.
    case token
    /// Cancellation takes effect at internal generation batches.
    case batch
    /// Cancellation is only observed when an attempt returns.
    case attemptBoundary
}

/// Residency and concurrency constraints reported by a provider.
public struct ModelResourceConstraints: Hashable, Codable, Sendable {
    /// Maximum simultaneous generation attempts for this provider lane.
    public let maximumConcurrentAttempts: UInt16
    /// Whether the provider owns resident local model resources.
    public let requiresResidentModel: Bool
    /// Whether switching selections requires draining the current attempt.
    public let requiresDrainBeforeSwitch: Bool

    /// Creates positive provider resource constraints.
    public init(
        maximumConcurrentAttempts: UInt16,
        requiresResidentModel: Bool,
        requiresDrainBeforeSwitch: Bool
    ) throws {
        guard maximumConcurrentAttempts > 0 else {
            throw AgentContractError.invalidName("model concurrency")
        }
        self.maximumConcurrentAttempts = maximumConcurrentAttempts
        self.requiresResidentModel = requiresResidentModel
        self.requiresDrainBeforeSwitch = requiresDrainBeforeSwitch
    }

    /// Decodes and revalidates provider concurrency constraints.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumConcurrentAttempts: container.decode(UInt16.self, forKey: .maximumConcurrentAttempts),
                requiresResidentModel: container.decode(Bool.self, forKey: .requiresResidentModel),
                requiresDrainBeforeSwitch: container.decode(Bool.self, forKey: .requiresDrainBeforeSwitch)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumConcurrentAttempts, requiresResidentModel, requiresDrainBeforeSwitch
    }
}

/// Provider-neutral capabilities for one exact model selection.
public struct AgentModelCapabilities: Hashable, Codable, Sendable {
    /// Maximum complete model context tokens.
    public let maximumContextTokens: UInt64
    /// Maximum generated output tokens.
    public let maximumOutputTokens: UInt64
    /// Supported feature set.
    public let features: AgentModelCapabilitySet
    /// Tool-call transport.
    public let toolCallingMode: ModelToolCallingMode
    /// Cancellation granularity.
    public let cancellationGranularity: ModelCancellationGranularity
    /// Provider resource constraints.
    public let resourceConstraints: ModelResourceConstraints
    /// Whether exact provider-tokenizer usage is reported.
    public let reportsTokenUsage: Bool
    /// Whether the provider reports cost fields; local providers report zero or no cost.
    public let reportsCost: Bool

    /// Creates positive bounded model capabilities.
    public init(
        maximumContextTokens: UInt64,
        maximumOutputTokens: UInt64,
        features: AgentModelCapabilitySet,
        toolCallingMode: ModelToolCallingMode,
        cancellationGranularity: ModelCancellationGranularity,
        resourceConstraints: ModelResourceConstraints,
        reportsTokenUsage: Bool,
        reportsCost: Bool
    ) throws {
        guard maximumContextTokens > 0, maximumOutputTokens > 0,
              maximumOutputTokens <= maximumContextTokens
        else { throw AgentContractError.invalidName("model token limits") }
        self.maximumContextTokens = maximumContextTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.features = features
        self.toolCallingMode = toolCallingMode
        self.cancellationGranularity = cancellationGranularity
        self.resourceConstraints = resourceConstraints
        self.reportsTokenUsage = reportsTokenUsage
        self.reportsCost = reportsCost
    }

    /// Decodes and revalidates token limits and resource constraints.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumContextTokens: container.decode(UInt64.self, forKey: .maximumContextTokens),
                maximumOutputTokens: container.decode(UInt64.self, forKey: .maximumOutputTokens),
                features: container.decode(AgentModelCapabilitySet.self, forKey: .features),
                toolCallingMode: container.decode(ModelToolCallingMode.self, forKey: .toolCallingMode),
                cancellationGranularity: container.decode(
                    ModelCancellationGranularity.self,
                    forKey: .cancellationGranularity
                ),
                resourceConstraints: container.decode(
                    ModelResourceConstraints.self,
                    forKey: .resourceConstraints
                ),
                reportsTokenUsage: container.decode(Bool.self, forKey: .reportsTokenUsage),
                reportsCost: container.decode(Bool.self, forKey: .reportsCost)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumContextTokens, maximumOutputTokens, features, toolCallingMode
        case cancellationGranularity, resourceConstraints, reportsTokenUsage, reportsCost
    }
}

/// Provider-neutral policy for whether a model may produce an internal reasoning phase.
public enum AgentModelThinkingMode: String, CaseIterable, Hashable, Codable, Sendable {
    /// Disable provider reasoning or thinking mode.
    case disabled
    /// Enable reasoning when the selected provider supports it.
    case enabled
    /// Let the runtime choose deterministically from the pinned model capabilities and task shape.
    case automatic
}

/// Complete provider-neutral generation controls frozen for one model attempt.
public struct AgentModelGenerationParameters: Hashable, Codable, Sendable {
    /// Hard generated-token ceiling for this attempt.
    public let maximumOutputTokens: UInt64
    /// Hard complete-context ceiling used when compiling this attempt.
    public let maximumContextTokens: UInt64
    /// Sampling temperature in the closed range zero through two.
    public let temperature: Double
    /// Nucleus-sampling mass in the open-closed range zero through one.
    public let topP: Double
    /// Optional positive top-k sampling limit; nil explicitly disables a top-k limit.
    public let topK: UInt32?
    /// Positive provider-neutral repetition penalty.
    public let repetitionPenalty: Double
    /// Frozen reasoning policy.
    public let thinkingMode: AgentModelThinkingMode
    /// Optional deterministic seed; nil explicitly requests an unseeded attempt.
    public let seed: UInt64?

    /// Creates finite, canonicalizable generation controls.
    public init(
        maximumOutputTokens: UInt64,
        maximumContextTokens: UInt64,
        temperature: Double,
        topP: Double,
        topK: UInt32?,
        repetitionPenalty: Double,
        thinkingMode: AgentModelThinkingMode,
        seed: UInt64?
    ) throws {
        let maximumIJSONInteger: UInt64 = 9_007_199_254_740_991
        guard maximumOutputTokens > 0,
              maximumContextTokens >= maximumOutputTokens,
              maximumContextTokens <= maximumIJSONInteger,
              temperature.isFinite, (0 ... 2).contains(temperature),
              topP.isFinite, topP > 0, topP <= 1,
              topK.map({ $0 > 0 }) ?? true,
              repetitionPenalty.isFinite, repetitionPenalty > 0, repetitionPenalty <= 100,
              seed.map({ $0 <= maximumIJSONInteger }) ?? true
        else { throw AgentContractError.invalidName("model generation parameters") }
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumContextTokens = maximumContextTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.thinkingMode = thinkingMode
        self.seed = seed
    }

    /// Conservative compatibility defaults; production compilers should pass explicit values.
    public static let standard = try! Self(
        maximumOutputTokens: 1_024,
        maximumContextTokens: 4_096,
        temperature: 0.7,
        topP: 1,
        topK: nil,
        repetitionPenalty: 1,
        thinkingMode: .automatic,
        seed: nil
    )

    /// Decodes and revalidates every generation-control bound.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumOutputTokens: container.decode(UInt64.self, forKey: .maximumOutputTokens),
                maximumContextTokens: container.decode(UInt64.self, forKey: .maximumContextTokens),
                temperature: container.decode(Double.self, forKey: .temperature),
                topP: container.decode(Double.self, forKey: .topP),
                topK: container.decodeIfPresent(UInt32.self, forKey: .topK),
                repetitionPenalty: container.decode(Double.self, forKey: .repetitionPenalty),
                thinkingMode: container.decode(AgentModelThinkingMode.self, forKey: .thinkingMode),
                seed: container.decodeIfPresent(UInt64.self, forKey: .seed)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumOutputTokens, maximumContextTokens, temperature, topP, topK
        case repetitionPenalty, thinkingMode, seed
    }
}

/// Provider-neutral role of one compiled model message.
public enum AgentModelMessageRole: String, CaseIterable, Hashable, Codable, Sendable {
    /// Trusted runtime policy.
    case system
    /// User-provided content.
    case user
    /// Prior assistant content.
    case assistant
    /// Untrusted tool or external result content.
    case tool
}

/// One bounded item in a compiled provider-neutral model request.
public struct AgentModelMessage: Hashable, Codable, Sendable {
    /// Message role.
    public let role: AgentModelMessageRole
    /// Text body or bounded excerpt.
    public let content: String
    /// Whether content must be treated as untrusted data rather than control instructions.
    public let isUntrustedData: Bool
    /// Referenced artifacts supplied with this message.
    public let artifacts: [ArtifactReference]

    /// Creates one bounded model message.
    public init(
        role: AgentModelMessageRole,
        content: String,
        isUntrustedData: Bool,
        artifacts: [ArtifactReference] = []
    ) throws {
        guard content.utf8.count <= 8 * 1_024 * 1_024,
              Set(artifacts.map(\.id)).count == artifacts.count
        else {
            throw AgentContractError.invalidName("model message too large")
        }
        if role == .tool, !isUntrustedData {
            throw AgentContractError.invalidName("tool content must be untrusted")
        }
        self.role = role
        self.content = content
        self.isUntrustedData = isUntrustedData
        self.artifacts = artifacts
    }

    /// Decodes and revalidates size, trust framing, and artifact uniqueness.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                role: container.decode(AgentModelMessageRole.self, forKey: .role),
                content: container.decode(String.self, forKey: .content),
                isUntrustedData: container.decode(Bool.self, forKey: .isUntrustedData),
                artifacts: container.decode([ArtifactReference].self, forKey: .artifacts)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case role, content, isUntrustedData, artifacts }
}

/// One selected descriptor and the deterministic rationale codes that admitted it.
public struct AgentToolSelectionDecision: Hashable, Codable, Sendable {
    /// Exact descriptor selected for the model pass.
    public let descriptorID: AgentToolDescriptorID
    /// Stable, nonlocalized reason codes used for testing and inspection.
    public let rationaleCodes: [String]

    /// Creates a decision with at least one canonical rationale code.
    public init(
        descriptorID: AgentToolDescriptorID,
        rationaleCodes: some Sequence<String>
    ) throws {
        let rationaleCodes = Array(Set(rationaleCodes)).sorted()
        guard !rationaleCodes.isEmpty,
              rationaleCodes.allSatisfy({
                  AgentWireValidation.isLowercaseNamespace($0, maximumLength: 128)
              })
        else { throw AgentContractError.invalidName("tool selection rationale") }
        self.descriptorID = descriptorID
        self.rationaleCodes = rationaleCodes
    }

    /// Decodes and rejects duplicate or noncanonical rationale codes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rationaleCodes = try container.decode([String].self, forKey: .rationaleCodes)
        do {
            try self.init(
                descriptorID: container.decode(AgentToolDescriptorID.self, forKey: .descriptorID),
                rationaleCodes: rationaleCodes
            )
            guard self.rationaleCodes == rationaleCodes else {
                throw AgentContractError.invalidName("noncanonical tool selection rationale")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case descriptorID, rationaleCodes }
}

/// Frozen input, ordered output, and rationale of the deterministic tool selector.
public struct AgentToolSelectionSnapshot: Hashable, Codable, Sendable {
    /// Stable selector implementation or policy identity.
    public let selectorID: String
    /// Conversation tool-selection policy version used for this pass.
    public let policyVersion: UInt32
    /// Digest of complete selector inputs, including allowed/pinned sets and request features.
    public let inputDigest: StableDigest
    /// Ordered selected output; order is preserved because it can affect small-model behavior.
    public let decisions: [AgentToolSelectionDecision]

    /// Creates a bounded selector snapshot without reordering its output.
    public init(
        selectorID: String,
        policyVersion: UInt32,
        inputDigest: StableDigest,
        decisions: [AgentToolSelectionDecision]
    ) throws {
        let descriptorIDs = decisions.map(\.descriptorID)
        guard AgentWireValidation.isLowercaseNamespace(selectorID, maximumLength: 128),
              policyVersion > 0,
              decisions.count <= 64,
              Set(descriptorIDs).count == decisions.count,
              Set(descriptorIDs.map(\.logicalID)).count == decisions.count
        else { throw AgentContractError.invalidName("tool selection snapshot") }
        self.selectorID = selectorID
        self.policyVersion = policyVersion
        self.inputDigest = inputDigest
        self.decisions = decisions
    }

    /// Decodes and revalidates selector identity, policy, and ordered output uniqueness.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                selectorID: container.decode(String.self, forKey: .selectorID),
                policyVersion: container.decode(UInt32.self, forKey: .policyVersion),
                inputDigest: container.decode(StableDigest.self, forKey: .inputDigest),
                decisions: container.decode([AgentToolSelectionDecision].self, forKey: .decisions)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case selectorID, policyVersion, inputDigest, decisions
    }
}

/// Immutable compiled request handed to a model-provider adapter.
public struct AgentModelRequest: Hashable, Codable, Sendable {
    /// Owning request identity.
    public let requestID: AgentRequestID
    /// Owning run.
    public let runID: AgentRunID
    /// Stable model-attempt step.
    public let stepID: AgentStepID
    /// Exact model selection pinned for the run.
    public let selection: AgentModelSelection
    /// Digest of the complete immutable compiled-request manifest.
    public let compiledManifestDigest: StableDigest
    /// Ordered compiled messages.
    public let messages: [AgentModelMessage]
    /// Complete exact tool descriptors advertised for this attempt.
    public let advertisedTools: [AgentToolDescriptor]
    /// Frozen selector input, ordered output, policy version, and rationale codes.
    public let toolSelectionSnapshot: AgentToolSelectionSnapshot
    /// Complete provider-neutral generation controls frozen for this attempt.
    public let generationParameters: AgentModelGenerationParameters
    /// Output contract for the attempt.
    public let outputRequirement: AgentOutputRequirement

    /// Exact descriptor identities in the same canonical order as `advertisedTools`.
    public var advertisedToolIDs: [AgentToolDescriptorID] { advertisedTools.map(\.id) }

    /// Creates an immutable model request with deterministic tool ordering.
    public init(
        requestID: AgentRequestID,
        runID: AgentRunID,
        stepID: AgentStepID,
        selection: AgentModelSelection,
        compiledManifestDigest: StableDigest,
        messages: [AgentModelMessage],
        advertisedTools: [AgentToolDescriptor],
        toolSelectionSnapshot: AgentToolSelectionSnapshot,
        generationParameters: AgentModelGenerationParameters,
        outputRequirement: AgentOutputRequirement
    ) throws {
        try outputRequirement.validate()
        guard !messages.isEmpty, messages.count <= 4_096,
              advertisedTools.count <= 64,
              Set(advertisedTools.map(\.id)).count == advertisedTools.count,
              Set(advertisedTools.map(\.id.logicalID)).count == advertisedTools.count,
              toolSelectionSnapshot.decisions.map(\.descriptorID) == advertisedTools.map(\.id)
        else {
            throw AgentContractError.invalidName("model request")
        }
        self.requestID = requestID
        self.runID = runID
        self.stepID = stepID
        self.selection = selection
        self.compiledManifestDigest = compiledManifestDigest
        self.messages = messages
        self.advertisedTools = advertisedTools
        self.toolSelectionSnapshot = toolSelectionSnapshot
        self.generationParameters = generationParameters
        self.outputRequirement = outputRequirement
    }

    /// Decodes and revalidates message presence and unique advertised descriptors.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let advertisedTools = try container.decode([AgentToolDescriptor].self, forKey: .advertisedTools)
        do {
            try self.init(
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                stepID: container.decode(AgentStepID.self, forKey: .stepID),
                selection: container.decode(AgentModelSelection.self, forKey: .selection),
                compiledManifestDigest: container.decode(
                    StableDigest.self,
                    forKey: .compiledManifestDigest
                ),
                messages: container.decode([AgentModelMessage].self, forKey: .messages),
                advertisedTools: advertisedTools,
                toolSelectionSnapshot: container.decode(
                    AgentToolSelectionSnapshot.self,
                    forKey: .toolSelectionSnapshot
                ),
                generationParameters: container.decode(
                    AgentModelGenerationParameters.self,
                    forKey: .generationParameters
                ),
                outputRequirement: container.decode(
                    AgentOutputRequirement.self,
                    forKey: .outputRequirement
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, runID, stepID, selection, compiledManifestDigest, messages
        case advertisedTools, toolSelectionSnapshot, generationParameters, outputRequirement
    }

    /// Canonical authorization payload binding every execution-relevant model request field.
    public func authorizationPayload() throws -> CanonicalJSON {
        func artifactValue(_ artifact: ArtifactReference) -> JSONValue {
            .object([
                "id": .string(artifact.id.description),
                "digest": .string(artifact.contentDigest.rawValue),
                "bytes": .unsignedInteger(artifact.byteCount),
                "mime": .string(artifact.mimeType),
                "semanticType": artifact.semanticType.map(JSONValue.string) ?? .null,
                "createdAt": .integer(artifact.createdAt.rawValue),
                "retention": .string(artifact.retentionPolicy.rawValue),
                "sensitivity": .string(artifact.sensitivity.rawValue),
                "integrity": .string(artifact.integrityStatus.rawValue),
                "locator": .object([
                    "kind": .string(artifact.locator.kind.rawValue),
                    "value": .string(artifact.locator.value),
                    "providerID": artifact.locator.providerID.map(JSONValue.string) ?? .null,
                ]),
                "provenance": .object([
                    "runID": artifact.provenance.runID.map { .string($0.description) } ?? .null,
                    "stepID": artifact.provenance.stepID.map { .string($0.description) } ?? .null,
                    "invocationID": artifact.provenance.invocationID.map {
                        .string($0.description)
                    } ?? .null,
                    "externalOperationFingerprint": artifact.provenance
                        .externalOperationFingerprint.map { .string($0.rawValue) } ?? .null,
                    "providerID": artifact.provenance.providerID.map(JSONValue.string) ?? .null,
                ]),
            ])
        }
        func schemaValue(_ schema: JSONSchemaDocument) -> JSONValue {
            .object([
                "root": schema.root,
                "digest": .string(schema.digest.rawValue),
                "enforcement": .string(schema.enforcement.rawValue),
                "unenforcedKeywords": .array(schema.unenforcedKeywords.map(JSONValue.string)),
                "limits": .object([
                    "maximumEncodedBytes": .unsignedInteger(schema.limits.maximumEncodedBytes),
                    "maximumNestingDepth": .unsignedInteger(UInt64(schema.limits.maximumNestingDepth)),
                    "maximumResolvedNodes": .unsignedInteger(UInt64(schema.limits.maximumResolvedNodes)),
                    "maximumLocalReferenceDepth": .unsignedInteger(
                        UInt64(schema.limits.maximumLocalReferenceDepth)
                    ),
                    "maximumPatternLength": .unsignedInteger(UInt64(schema.limits.maximumPatternLength)),
                ]),
            ])
        }
        func descriptorValue(_ descriptor: AgentToolDescriptor) -> JSONValue {
            .object([
                "id": .object([
                    "provider": .string(descriptor.id.logicalID.providerID),
                    "name": .string(descriptor.id.logicalID.name),
                    "version": .string(descriptor.id.version.description),
                    "schema": .string(descriptor.id.schemaDigest.rawValue),
                    "trust": .string(descriptor.id.trustRevision),
                ]),
                "title": .string(descriptor.title),
                "summary": .string(descriptor.summary),
                "inputSchema": schemaValue(descriptor.inputSchema),
                "outputSchema": descriptor.outputSchema.map(schemaValue) ?? .null,
                "effects": .array(descriptor.effects.map { .string($0.rawValue) }),
                "requiredCapabilities": .array(
                    descriptor.requiredCapabilities.values.map { .string($0.rawValue) }
                ),
                "timeoutMilliseconds": .unsignedInteger(descriptor.timeoutPolicy.maximumMilliseconds),
                "retry": .object([
                    "kind": .string(descriptor.retryPolicy.kind.rawValue),
                    "maximumAttempts": .unsignedInteger(UInt64(descriptor.retryPolicy.maximumAttempts)),
                    "baseDelayMilliseconds": .unsignedInteger(
                        descriptor.retryPolicy.baseDelayMilliseconds
                    ),
                    "maximumDelayMilliseconds": .unsignedInteger(
                        descriptor.retryPolicy.maximumDelayMilliseconds
                    ),
                    "allowsJitter": .bool(descriptor.retryPolicy.allowsJitter),
                ]),
                "idempotency": .string(descriptor.idempotency.rawValue),
                "supportsProgress": .bool(descriptor.supportsProgress),
                "supportsCancellation": .bool(descriptor.supportsCancellation),
            ])
        }
        let output: JSONValue = switch outputRequirement {
        case .text:
            .object(["kind": .string("text")])
        case .structured(let schema):
            .object(["kind": .string("structured"), "schema": .string(schema.digest.rawValue)])
        case .artifacts(let semanticType):
            .object(["kind": .string("artifacts"), "semanticType": .string(semanticType)])
        case .textAndArtifacts:
            .object(["kind": .string("textAndArtifacts")])
        }
        let value: JSONValue = .object([
            "requestID": .string(requestID.description),
            "runID": .string(runID.description),
            "stepID": .string(stepID.description),
            "providerID": .string(selection.providerID.rawValue),
            "modelID": .string(selection.modelID.rawValue),
            "variantID": .string(selection.variantID.rawValue),
            "capabilityVersion": .string(selection.capabilityVersion.description),
            "compiledManifestDigest": .string(compiledManifestDigest.rawValue),
            "messages": .array(messages.map { message in
                .object([
                    "role": .string(message.role.rawValue),
                    "content": .string(message.content),
                    "untrusted": .bool(message.isUntrustedData),
                    "artifacts": .array(message.artifacts.map(artifactValue)),
                ])
            }),
            "advertisedTools": .array(advertisedTools.map(descriptorValue)),
            "toolSelection": .object([
                "selectorID": .string(toolSelectionSnapshot.selectorID),
                "policyVersion": .unsignedInteger(UInt64(toolSelectionSnapshot.policyVersion)),
                "inputDigest": .string(toolSelectionSnapshot.inputDigest.rawValue),
                "decisions": .array(toolSelectionSnapshot.decisions.map { decision in
                    .object([
                        "descriptorID": .string(decision.descriptorID.description),
                        "rationaleCodes": .array(
                            decision.rationaleCodes.map(JSONValue.string)
                        ),
                    ])
                }),
            ]),
            "generation": .object([
                "maximumOutputTokens": .unsignedInteger(generationParameters.maximumOutputTokens),
                "maximumContextTokens": .unsignedInteger(generationParameters.maximumContextTokens),
                "temperature": .number(generationParameters.temperature),
                "topP": .number(generationParameters.topP),
                "topK": generationParameters.topK.map {
                    .unsignedInteger(UInt64($0))
                } ?? .null,
                "repetitionPenalty": .number(generationParameters.repetitionPenalty),
                "thinkingMode": .string(generationParameters.thinkingMode.rawValue),
                "seed": generationParameters.seed.map(JSONValue.unsignedInteger) ?? .null,
            ]),
            "output": output,
        ])
        return try CanonicalJSON(value)
    }

    /// Deterministic fingerprint of the complete authorization payload.
    public func fingerprint() throws -> StableDigest { try authorizationPayload().fingerprint }
}

/// Model request after side-effect-free provider preparation.
public struct PreparedModelRequest: Hashable, Codable, Sendable {
    /// Provider-neutral model payload.
    public let request: AgentModelRequest
    /// Shared external-operation transaction, local-pure for first-release providers.
    public let externalOperation: PreparedExternalOperationRequest

    /// Binds one model request to a shared prepared-operation plan.
    public init(request: AgentModelRequest, externalOperation: PreparedExternalOperationRequest) throws {
        let payload = try request.authorizationPayload()
        guard request.requestID == externalOperation.requestID,
              request.runID == externalOperation.runID,
              request.stepID == externalOperation.stepID,
              externalOperation.plan.kind == .localPure || externalOperation.plan.kind == .modelProvider,
              externalOperation.payload.value == payload,
              externalOperation.plan.kind != .modelProvider
                || externalOperation.plan.payloadDigest == payload.fingerprint
        else { throw AgentContractError.authorizationBindingMismatch("prepared model request") }
        self.request = request
        self.externalOperation = externalOperation
    }

    /// Decodes and revalidates exact model-payload binding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                request: container.decode(AgentModelRequest.self, forKey: .request),
                externalOperation: container.decode(
                    PreparedExternalOperationRequest.self,
                    forKey: .externalOperation
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case request, externalOperation }
}

/// Runtime-owned sink receiving model events while an authorization gate remains active.
public protocol AgentModelEventSink: Sendable {
    /// Consumes one validated event before the provider boundary completes.
    func receive(_ event: AgentModelEvent) async throws
}

/// Closed eager completion returned by a provider after its event producer has finished.
public struct AgentModelBoundaryCompletion: Hashable, Codable, Sendable {
    /// Stable attempt outcome; token streams and tasks cannot be transported here.
    public let outcome: AgentModelAttemptOutcome
    /// Optional digest of the complete consumed provider response.
    public let responseDigest: StableDigest?

    /// Creates eager provider completion evidence.
    public init(
        outcome: AgentModelAttemptOutcome,
        responseDigest: StableDigest? = nil
    ) {
        self.outcome = outcome
        self.responseDigest = responseDigest
    }
}

/// Result issued after the gate closes streaming and its hard byte accumulator.
public struct AgentModelBoundaryResult: Hashable, Codable, Sendable {
    /// Stable eager attempt outcome.
    public let outcome: AgentModelAttemptOutcome
    /// Response bytes admitted before streaming each provider event.
    public let responseBytes: UInt64
    /// Optional digest of the complete consumed provider response.
    public let responseDigest: StableDigest?

    fileprivate init(
        outcome: AgentModelAttemptOutcome,
        responseBytes: UInt64,
        responseDigest: StableDigest?
    ) {
        self.outcome = outcome
        self.responseBytes = responseBytes
        self.responseDigest = responseDigest
    }
}

/// Model request carrying a gate that revalidates immediately before each provider boundary.
public struct AuthorizedModelRequest: Sendable {
    /// Original model request.
    public let request: AgentModelRequest
    /// Durable structurally bound authorization; its expiry is not trusted until gate execution.
    public let authorization: AuthorizedExternalOperationRequest

    private let executionGate: ExternalExecutionAuthorizationGate

    /// Creates a model request that only a provider's generate operation may consume.
    @_spi(AgentRuntime)
    public init(
        request: AgentModelRequest,
        authorization: AuthorizedExternalOperationRequest,
        clock: any AgentAuthorizationClock,
        policyValidator: any AgentAuthorizationPolicyValidating,
        attemptLedger: any ExternalOperationAttemptClaiming
    ) throws {
        guard request.requestID == authorization.prepared.requestID,
              request.runID == authorization.prepared.runID,
              request.stepID == authorization.prepared.stepID,
              try request.authorizationPayload() == authorization.prepared.payload.value
        else { throw AgentContractError.authorizationBindingMismatch("authorized model request") }
        self.request = request
        self.authorization = authorization
        executionGate = authorization.executionGate(
            clock: clock,
            policyValidator: policyValidator,
            attemptLedger: attemptLedger
        )
    }

    /// Runs one provider producer while forwarding deltas through a gate-owned live emitter.
    ///
    /// A provider may expose an `AsyncThrowingStream` to its caller, but its producer task must
    /// await this method and route every event through `AgentModelBoundaryEmitter`. Deltas reach
    /// the sink immediately; the stream itself cannot be returned as the eager boundary result.
    public func performGenerationBoundary(
        observation: ExternalOperationObservation,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop,
        sink: any AgentModelEventSink,
        operation: @escaping @Sendable (
            AgentModelRequest,
            AgentModelBoundaryEmitter
        ) async throws -> AgentModelBoundaryCompletion
    ) async throws -> AgentModelBoundaryResult {
        let boundary = try await executionGate.perform(
            observation: observation,
            attempt: attempt,
            hop: hop
        ) { control in
            let emitter = AgentModelBoundaryEmitter(control: control, sink: sink)
            do {
                let completion = try await operation(request, emitter)
                try await emitter.finish(with: completion.outcome)
                return ExternalOperationBoundaryCompletion(
                    value: .modelOutcome(completion.outcome),
                    responseDigest: completion.responseDigest
                )
            } catch {
                await emitter.invalidate()
                throw error
            }
        }
        guard case .modelOutcome(let outcome) = boundary.value else {
            throw AgentContractError.authorizationBindingMismatch("model boundary result")
        }
        return AgentModelBoundaryResult(
            outcome: outcome,
            responseBytes: boundary.responseBytes,
            responseDigest: boundary.responseDigest
        )
    }
}

/// Provider-reported usage for one model attempt.
public struct AgentModelUsage: Hashable, Codable, Sendable {
    /// Input tokens charged to the attempt.
    public let inputTokens: UInt64
    /// Generated tokens charged to the attempt.
    public let outputTokens: UInt64
    /// Active attempt duration.
    public let activeMilliseconds: UInt64
    /// Peak resident bytes reported for the attempt.
    public let peakMemoryBytes: UInt64
    /// Optional informational provider cost in micros; admission uses separately frozen budgets.
    public let reportedCostMicros: UInt64?
    /// ISO 4217 currency code for a reported cost.
    public let costCurrencyCode: String?

    /// Creates a usage report with internally paired cost fields.
    public init(
        inputTokens: UInt64,
        outputTokens: UInt64,
        activeMilliseconds: UInt64,
        peakMemoryBytes: UInt64,
        reportedCostMicros: UInt64? = nil,
        costCurrencyCode: String? = nil
    ) throws {
        let validCurrency = costCurrencyCode.map { code in
            code.utf8.count == 3 && code.unicodeScalars.allSatisfy { (0x41 ... 0x5A).contains($0.value) }
        } ?? true
        guard (reportedCostMicros == nil) == (costCurrencyCode == nil), validCurrency
        else { throw AgentContractError.invalidName("model cost report") }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.activeMilliseconds = activeMilliseconds
        self.peakMemoryBytes = peakMemoryBytes
        self.reportedCostMicros = reportedCostMicros
        self.costCurrencyCode = costCurrencyCode
    }

    /// Decodes and revalidates paired cost fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                inputTokens: container.decode(UInt64.self, forKey: .inputTokens),
                outputTokens: container.decode(UInt64.self, forKey: .outputTokens),
                activeMilliseconds: container.decode(UInt64.self, forKey: .activeMilliseconds),
                peakMemoryBytes: container.decode(UInt64.self, forKey: .peakMemoryBytes),
                reportedCostMicros: container.decodeIfPresent(UInt64.self, forKey: .reportedCostMicros),
                costCurrencyCode: container.decodeIfPresent(String.self, forKey: .costCurrencyCode)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, activeMilliseconds, peakMemoryBytes
        case reportedCostMicros, costCurrencyCode
    }

    fileprivate func isMonotonic(after previous: Self) -> Bool {
        guard inputTokens >= previous.inputTokens,
              outputTokens >= previous.outputTokens,
              activeMilliseconds >= previous.activeMilliseconds,
              peakMemoryBytes >= previous.peakMemoryBytes,
              costCurrencyCode == previous.costCurrencyCode
        else { return false }
        switch (reportedCostMicros, previous.reportedCostMicros) {
        case let (.some(current), .some(prior)): return current >= prior
        case (.none, .none): return true
        default: return false
        }
    }
}

/// Normalized event emitted by a model-provider adapter.
public enum AgentModelEvent: Hashable, Codable, Sendable {
    /// Ephemeral reasoning content, never treated as an authoritative recovery boundary.
    case reasoningDelta(String)
    /// Ephemeral answer content.
    case answerDelta(String)
    /// One normalized serial tool batch.
    case toolCalls([ProposedToolCall])
    /// The model explicitly asks for additional user input.
    case requestUserInput(UserInputRequest)
    /// Provider usage update.
    case usage(AgentModelUsage)
    /// Exactly one successful terminal completion.
    case completed(AgentModelCompletion)
    /// Exactly one typed terminal failure.
    case failed(AgentFailure)

    /// Whether this event terminates the model-attempt stream.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        default: false
        }
    }
}

/// Successful terminal metadata for one provider attempt.
public struct AgentModelCompletion: Hashable, Codable, Sendable {
    /// Normalized action selected from the complete provider output.
    public let action: AgentAction
    /// Final cumulative provider usage.
    public let usage: AgentModelUsage

    /// Creates successful terminal model metadata.
    public init(action: AgentAction, usage: AgentModelUsage) throws {
        try action.validate()
        self.action = action
        self.usage = usage
    }

    /// Decodes and revalidates the normalized terminal action.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                action: container.decode(AgentAction.self, forKey: .action),
                usage: container.decode(AgentModelUsage.self, forKey: .usage)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case action, usage }

    /// Validates the terminal action against the exact request and resolved descriptor snapshots.
    public func validate(
        against request: AgentModelRequest,
        resolvedToolDescriptors: [AgentToolDescriptor]
    ) throws {
        guard resolvedToolDescriptors == request.advertisedTools
        else { throw AgentContractError.invalidEventSequence("resolved tool manifest mismatch") }

        switch action {
        case .callTools(let calls):
            for call in calls {
                guard let descriptor = resolvedToolDescriptors.first(where: {
                    $0.id.logicalID == call.toolID
                }) else {
                    throw AgentContractError.invalidEventSequence("tool call was not advertised")
                }
                let arguments = try AgentWireDecoder.decode(
                    JSONValue.self,
                    from: call.arguments.data,
                    limits: .inlineValue
                )
                guard try descriptor.inputSchema.validates(instance: arguments) else {
                    throw AgentContractError.invalidEventSequence("tool arguments violate pinned schema")
                }
            }
        case .requestUserInput(let interaction):
            guard interaction.runID == request.runID else {
                throw AgentContractError.invalidEventSequence("interaction belongs to another run")
            }
        case .finalAnswer(let answer):
            switch request.outputRequirement {
            case .text:
                guard answer.text != nil else {
                    throw AgentContractError.invalidEventSequence("text answer required")
                }
            case .structured(let schema):
                guard let output = answer.structuredOutput,
                      try schema.validates(instance: output)
                else { throw AgentContractError.invalidEventSequence("structured answer invalid") }
            case .artifacts(let semanticType):
                guard !answer.artifacts.isEmpty,
                      answer.artifacts.allSatisfy({ $0.semanticType == semanticType })
                else { throw AgentContractError.invalidEventSequence("artifact answer invalid") }
            case .textAndArtifacts:
                guard answer.text != nil else {
                    throw AgentContractError.invalidEventSequence("text portion required")
                }
            }
        }
    }
}

/// Stable model-attempt outcome suitable for a durable journal event.
public enum AgentModelAttemptOutcome: Hashable, Codable, Sendable {
    /// The attempt produced one normalized action and final usage.
    case completed(AgentModelCompletion)
    /// The attempt was discarded at a non-stable token boundary and may restart from its manifest.
    case interrupted(AgentModelUsage?)
    /// The attempt ended with one typed failure.
    case failed(AgentFailure)
}

/// Gate-owned live emitter that accounts bytes before forwarding provider events.
///
/// The emitter becomes permanently invalid when the provider operation returns or throws. An
/// escaped producer therefore cannot publish additional events under an expired authorization.
public actor AgentModelBoundaryEmitter {
    private let control: ExternalOperationBoundaryControl
    private let sink: any AgentModelEventSink
    private var actionSignal: AgentAction?
    private var lastUsage: AgentModelUsage?
    private var terminalEvent: AgentModelEvent?
    private var isClosed = false
    private var isEmitting = false

    fileprivate init(
        control: ExternalOperationBoundaryControl,
        sink: any AgentModelEventSink
    ) {
        self.control = control
        self.sink = sink
    }

    /// Accounts the source chunk, validates ordering, and immediately forwards one event.
    public func emit(_ event: AgentModelEvent, responseBytes: UInt64) async throws {
        guard !isClosed, !isEmitting, terminalEvent == nil else {
            throw AgentContractError.authorizationBindingMismatch("closed model boundary emitter")
        }
        isEmitting = true
        defer { isEmitting = false }
        try await control.consumeResponseBytes(responseBytes)
        guard !isClosed else {
            throw AgentContractError.authorizationBindingMismatch("closed model boundary emitter")
        }
        switch event {
        case .reasoningDelta(let value), .answerDelta(let value):
            guard actionSignal == nil, !value.isEmpty, value.utf8.count <= 1_024 * 1_024 else {
                throw AgentContractError.invalidEventSequence("invalid model delta")
            }
        case .toolCalls(let calls):
            guard !calls.isEmpty, Set(calls.map(\.invocationID)).count == calls.count,
                  actionSignal == nil
            else { throw AgentContractError.invalidEventSequence("invalid model action signal") }
            actionSignal = .callTools(calls)
        case .requestUserInput(let request):
            guard actionSignal == nil else {
                throw AgentContractError.invalidEventSequence("multiple model action signals")
            }
            actionSignal = .requestUserInput(request)
        case .usage(let usage):
            guard lastUsage.map({ usage.isMonotonic(after: $0) }) ?? true else {
                throw AgentContractError.invalidEventSequence("model usage regressed")
            }
            lastUsage = usage
        case .completed(let completion):
            guard actionSignal.map({ $0 == completion.action }) ?? true,
                  lastUsage.map({ completion.usage.isMonotonic(after: $0) }) ?? true
            else { throw AgentContractError.invalidEventSequence("terminal model event conflicts") }
            terminalEvent = event
        case .failed:
            guard actionSignal == nil else {
                throw AgentContractError.invalidEventSequence("failed model pass emitted an action")
            }
            terminalEvent = event
        }
        try await sink.receive(event)
        guard !isClosed else {
            throw AgentContractError.authorizationBindingMismatch("closed model boundary emitter")
        }
    }

    fileprivate func finish(with outcome: AgentModelAttemptOutcome) throws {
        guard !isClosed, !isEmitting else {
            throw AgentContractError.authorizationBindingMismatch("closed model boundary emitter")
        }
        switch (outcome, terminalEvent) {
        case let (.completed(expected), .some(.completed(actual))) where expected == actual:
            break
        case let (.failed(expected), .some(.failed(actual))) where expected == actual:
            break
        case (.interrupted, .none) where actionSignal == nil:
            break
        default:
            throw AgentContractError.invalidEventSequence("model boundary outcome conflicts with stream")
        }
        isClosed = true
    }

    fileprivate func invalidate() {
        isClosed = true
    }
}

/// Pure validator for exactly-one-terminal normalized model-attempt streams.
public enum AgentModelEventStreamValidator {
    /// Rejects invalid deltas, empty tool batches, duplicate terminals, and post-terminal events.
    public static func validate(_ events: [AgentModelEvent], requireTerminal: Bool = true) throws {
        var terminalSeen = false
        var actionSignal: AgentAction?
        var lastUsage: AgentModelUsage?
        for event in events {
            if terminalSeen {
                throw AgentContractError.invalidEventSequence("model event follows terminal outcome")
            }
            switch event {
            case .reasoningDelta(let value), .answerDelta(let value):
                guard actionSignal == nil, !value.isEmpty, value.utf8.count <= 1_024 * 1_024 else {
                    throw AgentContractError.invalidEventSequence("invalid model delta")
                }
            case .toolCalls(let calls):
                guard !calls.isEmpty, Set(calls.map(\.invocationID)).count == calls.count else {
                    throw AgentContractError.invalidEventSequence("invalid model tool batch")
                }
                let action = AgentAction.callTools(calls)
                guard actionSignal == nil else {
                    throw AgentContractError.invalidEventSequence("multiple model action signals")
                }
                actionSignal = action
            case .requestUserInput(let request):
                guard actionSignal == nil else {
                    throw AgentContractError.invalidEventSequence("multiple model action signals")
                }
                actionSignal = .requestUserInput(request)
            case .completed(let completion):
                guard actionSignal.map({ $0 == completion.action }) ?? true else {
                    throw AgentContractError.invalidEventSequence("terminal model action conflicts")
                }
                guard lastUsage.map({ completion.usage.isMonotonic(after: $0) }) ?? true else {
                    throw AgentContractError.invalidEventSequence("terminal model usage conflicts")
                }
                terminalSeen = true
            case .failed:
                guard actionSignal == nil else {
                    throw AgentContractError.invalidEventSequence("failed model pass emitted an action")
                }
                terminalSeen = true
            case .usage(let usage):
                guard lastUsage.map({ usage.isMonotonic(after: $0) }) ?? true else {
                    throw AgentContractError.invalidEventSequence("model usage regressed")
                }
                lastUsage = usage
            }
        }
        if requireTerminal, !terminalSeen {
            throw AgentContractError.invalidEventSequence("model stream lacks terminal outcome")
        }
    }

    /// Validates stream structure and the terminal action against one exact model request.
    public static func validate(
        _ events: [AgentModelEvent],
        request: AgentModelRequest,
        resolvedToolDescriptors: [AgentToolDescriptor],
        requireTerminal: Bool = true
    ) throws {
        try validate(events, requireTerminal: requireTerminal)
        if case .completed(let completion)? = events.last {
            try completion.validate(
                against: request,
                resolvedToolDescriptors: resolvedToolDescriptors
            )
        }
    }
}
