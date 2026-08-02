// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import LLMCore

/// Stable failures raised before a local model crosses its generation boundary.
public enum LocalModelAdapterError: Error, Equatable, Sendable {
    case invalidRegistration(String)
    case duplicateSelection(AgentModelSelection)
    case selectionNotRegistered(AgentModelSelection)
    case modelNotResident(AgentModelSelection)
    case generationAlreadyActive
    case residencyTransitionInProgress
    case unloadWhileGenerating
    case artifactUnavailable(ArtifactID)
    case artifactIntegrityMismatch(ArtifactID)
    case artifactLimitExceeded
}

/// Exact metadata binding an Agent Harness selection to one `LLMCore` model artifact.
///
/// The selection is derived from the catalog model and variant identities. It is never inferred at
/// generation time, and no nearest-model or online fallback exists.
public struct LocalModelRegistration: Hashable, Sendable {
    public let selection: AgentModelSelection
    public let model: LLMModel
    public let variant: LLMVariant
    public let weightsDirectory: URL
    public let capabilities: AgentModelCapabilities
    public let toolDialect: ToolDialect

    /// Builds a registration for curated Bonsai/Gemma/Apple entries or an adopted GGUF entry.
    public init(
        providerID: AgentModelProviderID,
        capabilityVersion: SemanticVersion,
        model: LLMModel,
        variant: LLMVariant,
        weightsDirectory: URL,
        maximumOutputTokens: UInt64? = nil
    ) throws {
        guard model.variants.contains(variant),
              variant.backend != .awqUnsupported,
              model.architecture.nativeContext > 0,
              weightsDirectory.isFileURL
        else { throw LocalModelAdapterError.invalidRegistration(model.id) }

        let contextLimit = UInt64(model.architecture.nativeContext)
        let outputLimit = maximumOutputTokens ?? min(contextLimit, 8_192)
        guard outputLimit > 0, outputLimit <= contextLimit else {
            throw LocalModelAdapterError.invalidRegistration(model.id)
        }

        let selection = AgentModelSelection(
            providerID: providerID,
            modelID: try AgentModelID(model.id),
            variantID: try AgentModelVariantID(variant.id),
            capabilityVersion: capabilityVersion
        )
        var features: [AgentModelCapability] = [.textToolDialect, .multipleToolCalls]
        if model.architecture.thinkingCapable && model.architecture.reasoningStyle.canThink {
            features.append(.reasoning)
        }
        if variant.supportsVisionInput { features.append(.vision) }

        self.selection = selection
        self.model = model
        self.variant = variant
        self.weightsDirectory = weightsDirectory.standardizedFileURL
        capabilities = try AgentModelCapabilities(
            maximumContextTokens: contextLimit,
            maximumOutputTokens: outputLimit,
            features: AgentModelCapabilitySet(features),
            toolCallingMode: .textDialect,
            cancellationGranularity: .token,
            resourceConstraints: ModelResourceConstraints(
                maximumConcurrentAttempts: 1,
                requiresResidentModel: !variant.isSystemProvided,
                requiresDrainBeforeSwitch: true
            ),
            reportsTokenUsage: true,
            reportsCost: false
        )
        toolDialect = ToolDialect(model.architecture.promptTemplate)
    }
}

/// Owns exactly one `LLMEngine` and at most one resident selection.
///
/// The runtime's resource arbiter owns policy. This actor supplies the narrow lifecycle driver and
/// a generation lane shared with `LocalModelProvider`, preventing generation against stale residency.
public actor LLMCoreModelResidencyDriver: ModelResidencyDriver {
    private struct ActiveGeneration: Sendable {
        let id: UUID
        let selection: AgentModelSelection
        let cancel: @Sendable () -> Void
        let awaitCompletion: @Sendable () async -> Void
    }

    private let engine: any LLMEngine
    private let registrations: [AgentModelSelection: LocalModelRegistration]
    public nonisolated let registeredSelections: [AgentModelSelection]
    private var residentSelection: AgentModelSelection?
    private var activeGeneration: ActiveGeneration?
    private var lifecycleTransition = false

    public init(
        engine: any LLMEngine,
        registrations: [LocalModelRegistration]
    ) throws {
        var indexed: [AgentModelSelection: LocalModelRegistration] = [:]
        for registration in registrations {
            guard indexed.updateValue(registration, forKey: registration.selection) == nil else {
                throw LocalModelAdapterError.duplicateSelection(registration.selection)
            }
        }
        guard !indexed.isEmpty else {
            throw LocalModelAdapterError.invalidRegistration("empty local model registry")
        }
        self.engine = engine
        self.registrations = indexed
        registeredSelections = indexed.keys.sorted()
    }

    public func registration(
        for selection: AgentModelSelection
    ) throws -> LocalModelRegistration {
        guard let registration = registrations[selection] else {
            throw LocalModelAdapterError.selectionNotRegistered(selection)
        }
        return registration
    }

    public func load(selection: AgentModelSelection) async throws {
        let registration = try registration(for: selection)
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard activeGeneration == nil else {
            throw LocalModelAdapterError.generationAlreadyActive
        }
        if residentSelection == selection { return }

        lifecycleTransition = true
        defer { lifecycleTransition = false }
        if residentSelection != nil {
            residentSelection = nil
            await engine.unload()
        }
        do {
            try await engine.load(
                model: registration.model,
                variant: registration.variant,
                weightsDir: registration.weightsDirectory,
                progress: { _ in }
            )
            residentSelection = selection
        } catch {
            await engine.unload()
            residentSelection = nil
            throw error
        }
    }

    public func cancelAndDrain(selection: AgentModelSelection) async throws {
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard let active = activeGeneration, active.selection == selection else { return }
        active.cancel()
        await active.awaitCompletion()
        if activeGeneration?.id == active.id { activeGeneration = nil }
    }

    public func unload(selection: AgentModelSelection) async throws {
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard residentSelection == selection else { return }
        guard activeGeneration == nil else {
            throw LocalModelAdapterError.unloadWhileGenerating
        }

        lifecycleTransition = true
        residentSelection = nil
        defer { lifecycleTransition = false }
        await engine.unload()
    }

    func runGeneration(
        selection: AgentModelSelection,
        operation: @escaping @Sendable (any LLMEngine) async throws -> AgentModelBoundaryCompletion
    ) async throws -> AgentModelBoundaryCompletion {
        guard !lifecycleTransition else {
            throw LocalModelAdapterError.residencyTransitionInProgress
        }
        guard residentSelection == selection else {
            throw LocalModelAdapterError.modelNotResident(selection)
        }
        guard activeGeneration == nil else {
            throw LocalModelAdapterError.generationAlreadyActive
        }

        let id = UUID()
        let task = Task { try await operation(engine) }
        activeGeneration = ActiveGeneration(
            id: id,
            selection: selection,
            cancel: { task.cancel() },
            awaitCompletion: { _ = await task.result }
        )
        do {
            let completion = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if activeGeneration?.id == id { activeGeneration = nil }
            return completion
        } catch {
            if activeGeneration?.id == id { activeGeneration = nil }
            throw error
        }
    }

    /// Test/diagnostic projection; it never changes residency.
    public var currentResidentSelection: AgentModelSelection? { residentSelection }
}
