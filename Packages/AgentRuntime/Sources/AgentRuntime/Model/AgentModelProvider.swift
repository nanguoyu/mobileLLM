// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Where a model provider performs inference.
///
/// The first Agent Harness release admits only ``onDevice`` providers. The explicit remote
/// value is a compatibility seam: merely registering one never makes it eligible for fallback.
public enum AgentModelProviderLocation: String, CaseIterable, Hashable, Codable, Sendable {
    case onDevice
    case remote
}

/// Stable identity and compatibility revisions for one provider adapter.
public struct AgentModelProviderDescriptor: Hashable, Codable, Sendable {
    public let id: AgentModelProviderID
    public let adapterVersion: SemanticVersion
    public let capabilityVersion: SemanticVersion
    public let location: AgentModelProviderLocation

    public init(
        id: AgentModelProviderID,
        adapterVersion: SemanticVersion,
        capabilityVersion: SemanticVersion,
        location: AgentModelProviderLocation
    ) {
        self.id = id
        self.adapterVersion = adapterVersion
        self.capabilityVersion = capabilityVersion
        self.location = location
    }
}

/// Trusted, immutable inputs available to a provider's side-effect-free preparation stage.
public struct ModelPreparationContext: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    public let modelPolicy: AgentModelPolicy
    public let capabilityGrant: StepCapabilityGrant
    public let authorizationPayload: SanitizedCanonicalJSON
    public let maximumRequestBytes: UInt64
    public let maximumResponseBytes: UInt64
    public let timeoutMilliseconds: UInt64

    public init(
        conversationID: ConversationID,
        modelPolicy: AgentModelPolicy,
        capabilityGrant: StepCapabilityGrant,
        authorizationPayload: SanitizedCanonicalJSON,
        maximumRequestBytes: UInt64,
        maximumResponseBytes: UInt64,
        timeoutMilliseconds: UInt64
    ) throws {
        guard maximumRequestBytes >= 4,
              authorizationPayload.data.count <= maximumRequestBytes,
              maximumResponseBytes > 0,
              timeoutMilliseconds > 0
        else { throw AgentModelRuntimeError.invalidPreparationLimits }
        self.conversationID = conversationID
        self.modelPolicy = modelPolicy
        self.capabilityGrant = capabilityGrant
        self.authorizationPayload = authorizationPayload
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

/// Provider-neutral local-model adapter contract.
///
/// `prepare` is side-effect free. Generation receives a gate-owned emitter rather than a raw
/// authorization bearer. Only ``AgentModelExecutor`` can create that emitter, and it does so
/// inside `AuthorizedModelRequest.performGenerationBoundary`, immediately after TOCTOU checks.
/// Adapters normalize any model-specific text/tool dialect before emitting events.
public protocol AgentModelProvider: Sendable {
    var descriptor: AgentModelProviderDescriptor { get }

    /// Reads only registered or cached local metadata.
    func capabilities(for selection: AgentModelSelection) async throws -> AgentModelCapabilities

    /// Produces an immutable plan without loading a model or crossing a protected boundary.
    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest

    /// Performs one eager generation boundary and emits normalized events before returning.
    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion
}

/// An exact prepared attempt, including the capability snapshot used for validation.
public struct PreparedAgentModelAttempt: Sendable {
    public let providerDescriptor: AgentModelProviderDescriptor
    public let capabilities: AgentModelCapabilities
    public let preparedRequest: PreparedModelRequest

    fileprivate init(
        providerDescriptor: AgentModelProviderDescriptor,
        capabilities: AgentModelCapabilities,
        preparedRequest: PreparedModelRequest
    ) {
        self.providerDescriptor = providerDescriptor
        self.capabilities = capabilities
        self.preparedRequest = preparedRequest
    }
}

/// Immutable provider registry. Resolution is exact by the pinned provider ID and never falls
/// back to a different (especially remote) provider.
public struct StaticAgentModelProviderCatalog: Sendable {
    private let providers: [AgentModelProviderID: any AgentModelProvider]

    public init(providers: [any AgentModelProvider]) throws {
        var indexed: [AgentModelProviderID: any AgentModelProvider] = [:]
        for provider in providers {
            guard indexed.updateValue(provider, forKey: provider.descriptor.id) == nil else {
                throw AgentModelRuntimeError.duplicateProvider(provider.descriptor.id)
            }
        }
        self.providers = indexed
    }

    public func provider(
        for selection: AgentModelSelection
    ) throws -> any AgentModelProvider {
        guard let provider = providers[selection.providerID] else {
            throw AgentModelRuntimeError.providerNotFound(selection.providerID)
        }
        return provider
    }
}

/// Safe helper used by on-device adapters to build their local-pure preparation result.
public enum LocalAgentModelPreparation {
    public static func prepare(
        request: AgentModelRequest,
        context: ModelPreparationContext,
        provider: AgentModelProviderDescriptor
    ) throws -> PreparedModelRequest {
        guard provider.location == .onDevice,
              provider.id == request.selection.providerID,
              provider.capabilityVersion == request.selection.capabilityVersion,
              context.authorizationPayload.value == (try request.authorizationPayload())
        else { throw AgentModelRuntimeError.preparedRequestMismatch }

        let plan = try ExternalOperationPlan(
            kind: .localPure,
            subjectID: provider.id.rawValue,
            payloadDigest: context.authorizationPayload.fingerprint,
            effects: [AgentEffect.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            maximumRequestBytes: context.maximumRequestBytes,
            maximumResponseBytes: context.maximumResponseBytes,
            timeoutMilliseconds: context.timeoutMilliseconds,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: ""
        )
        let external = try PreparedExternalOperationRequest(
            requestID: request.requestID,
            runID: request.runID,
            conversationID: context.conversationID,
            stepID: request.stepID,
            plan: plan,
            payload: context.authorizationPayload,
            capabilityGrant: context.capabilityGrant
        )
        return try PreparedModelRequest(request: request, externalOperation: external)
    }
}

/// Validates selection, capability, and immutable-plan constraints around provider preparation.
public struct AgentModelRequestPreparer: Sendable {
    public init() {}

    public func prepare(
        provider: any AgentModelProvider,
        request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedAgentModelAttempt {
        let descriptor = provider.descriptor
        try Self.validateSelection(
            descriptor: descriptor,
            request: request,
            context: context
        )
        let capabilities = try await provider.capabilities(for: request.selection)
        try Self.validateCapabilities(
            capabilities,
            descriptor: descriptor,
            request: request,
            policy: context.modelPolicy
        )
        let prepared = try await provider.prepare(request, context: context)
        guard provider.descriptor == descriptor else {
            throw AgentModelRuntimeError.providerDescriptorChanged
        }
        try Self.validatePrepared(
            prepared,
            descriptor: descriptor,
            request: request,
            context: context
        )
        return PreparedAgentModelAttempt(
            providerDescriptor: descriptor,
            capabilities: capabilities,
            preparedRequest: prepared
        )
    }

    private static func validateSelection(
        descriptor: AgentModelProviderDescriptor,
        request: AgentModelRequest,
        context: ModelPreparationContext
    ) throws {
        guard descriptor.location == .onDevice, context.modelPolicy.localOnly else {
            throw AgentModelRuntimeError.onlineProviderForbidden
        }
        guard descriptor.id == request.selection.providerID else {
            throw AgentModelRuntimeError.providerSelectionMismatch
        }
        guard descriptor.capabilityVersion == request.selection.capabilityVersion else {
            throw AgentModelRuntimeError.capabilityVersionMismatch
        }
        guard context.modelPolicy.allowedSelections.contains(request.selection) else {
            throw AgentModelRuntimeError.selectionNotAllowed
        }
        if context.modelPolicy.strategy == .pinned,
           context.modelPolicy.allowedSelections.first != request.selection
        {
            throw AgentModelRuntimeError.selectionNotPinned
        }
        guard context.authorizationPayload.value == (try request.authorizationPayload()),
              context.authorizationPayload.data.count <= context.maximumRequestBytes
        else { throw AgentModelRuntimeError.preparedRequestMismatch }
    }

    private static func validateCapabilities(
        _ capabilities: AgentModelCapabilities,
        descriptor: AgentModelProviderDescriptor,
        request: AgentModelRequest,
        policy: AgentModelPolicy
    ) throws {
        let missing = policy.requiredCapabilities.values.filter {
            !capabilities.features.contains($0)
        }
        guard missing.isEmpty else {
            throw AgentModelRuntimeError.missingCapabilities(AgentModelCapabilitySet(missing))
        }
        guard request.generationParameters.maximumContextTokens
                <= capabilities.maximumContextTokens,
              request.generationParameters.maximumOutputTokens
                <= capabilities.maximumOutputTokens
        else { throw AgentModelRuntimeError.modelTokenLimitExceeded }

        switch capabilities.toolCallingMode {
        case .textDialect:
            guard capabilities.features.contains(.textToolDialect) else {
                throw AgentModelRuntimeError.inconsistentCapabilities
            }
        case .nativeStructured:
            guard capabilities.features.contains(.nativeToolCalling) else {
                throw AgentModelRuntimeError.inconsistentCapabilities
            }
        case .unavailable:
            guard request.advertisedTools.isEmpty else {
                throw AgentModelRuntimeError.toolCallingUnavailable
            }
        }
        if request.generationParameters.thinkingMode == .enabled,
           !capabilities.features.contains(.reasoning)
        {
            throw AgentModelRuntimeError.missingCapabilities(
                AgentModelCapabilitySet([.reasoning])
            )
        }
        let containsImage = request.messages.lazy.flatMap(\.artifacts).contains {
            $0.mimeType.lowercased().hasPrefix("image/")
        }
        if containsImage, !capabilities.features.contains(.vision) {
            throw AgentModelRuntimeError.missingCapabilities(AgentModelCapabilitySet([.vision]))
        }
    }

    private static func validatePrepared(
        _ prepared: PreparedModelRequest,
        descriptor: AgentModelProviderDescriptor,
        request: AgentModelRequest,
        context: ModelPreparationContext
    ) throws {
        let external = prepared.externalOperation
        let plan = external.plan
        guard prepared.request == request,
              external.requestID == request.requestID,
              external.runID == request.runID,
              external.conversationID == context.conversationID,
              external.stepID == request.stepID,
              external.invocationID == nil,
              external.payload == context.authorizationPayload,
              external.capabilityGrant == context.capabilityGrant,
              plan.kind == .localPure,
              plan.subjectID == descriptor.id.rawValue,
              plan.effects == [.localPure],
              plan.requiredCapabilities.values.isEmpty,
              plan.maximumRequestBytes <= context.maximumRequestBytes,
              plan.maximumResponseBytes <= context.maximumResponseBytes,
              plan.timeoutMilliseconds <= context.timeoutMilliseconds,
              plan.retryPolicy == .never,
              plan.idempotency == .pureRead,
              plan.payloadDigest == context.authorizationPayload.fingerprint,
              plan.descriptorID == nil,
              plan.schemaDigest == nil,
              plan.trustRevision == nil,
              plan.credentialReference == nil
        else { throw AgentModelRuntimeError.preparedRequestMismatch }
    }
}

public enum AgentModelRuntimeError: Error, Equatable, Sendable {
    case invalidPreparationLimits
    case duplicateProvider(AgentModelProviderID)
    case providerNotFound(AgentModelProviderID)
    case onlineProviderForbidden
    case providerSelectionMismatch
    case capabilityVersionMismatch
    case selectionNotAllowed
    case selectionNotPinned
    case missingCapabilities(AgentModelCapabilitySet)
    case modelTokenLimitExceeded
    case inconsistentCapabilities
    case toolCallingUnavailable
    case preparedRequestMismatch
    case providerDescriptorChanged
    case authorizationBindingMismatch
    case executingWrongProvider
    case providerContractViolation(AgentContractError)
    case authorizationRejected(AgentContractError)
}
