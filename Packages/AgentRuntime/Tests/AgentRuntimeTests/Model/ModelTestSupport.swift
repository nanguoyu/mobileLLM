// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation

struct ModelFixture {
    let descriptor: AgentModelProviderDescriptor
    let capabilities: AgentModelCapabilities
    let request: AgentModelRequest
    let context: ModelPreparationContext
    let ceiling: RunCapabilityCeiling
    let authority: TrustedRunAuthority

    init(
        location: AgentModelProviderLocation = .onDevice,
        features: AgentModelCapabilitySet = AgentModelCapabilitySet([.reasoning]),
        toolCallingMode: ModelToolCallingMode = .unavailable,
        thinkingMode: AgentModelThinkingMode = .automatic,
        advertisedTools: [AgentToolDescriptor] = [],
        messageArtifacts: [ArtifactReference] = [],
        requiredCapabilities: AgentModelCapabilitySet = AgentModelCapabilitySet([]),
        maximumContextTokens: UInt64 = 4_096,
        maximumOutputTokens: UInt64 = 1_024,
        outputBudgetMode: AgentOutputBudgetMode = .explicit,
        reportsCost: Bool = false,
        offset: Int = 0,
        providerID: String? = nil,
        remoteDestination: String? = nil,
        modelID: String? = nil,
        userMessage: String? = nil
    ) throws {
        let version = SemanticVersion("1.0.0")!
        let resolvedProviderID = providerID ?? "local.scripted.\(offset)"
        descriptor = AgentModelProviderDescriptor(
            id: try AgentModelProviderID(resolvedProviderID),
            adapterVersion: version,
            capabilityVersion: version,
            location: location
        )
        capabilities = try AgentModelCapabilities(
            maximumContextTokens: maximumContextTokens,
            maximumOutputTokens: maximumOutputTokens,
            features: features,
            toolCallingMode: toolCallingMode,
            cancellationGranularity: .token,
            resourceConstraints: ModelResourceConstraints(
                maximumConcurrentAttempts: 1,
                requiresResidentModel: true,
                requiresDrainBeforeSwitch: true
            ),
            reportsTokenUsage: true,
            reportsCost: reportsCost
        )
        let selection = AgentModelSelection(
            providerID: descriptor.id,
            modelID: try AgentModelID(modelID ?? "fixture-model"),
            variantID: try AgentModelVariantID("fixture-variant"),
            capabilityVersion: version
        )
        let decisions = try advertisedTools.map {
            try AgentToolSelectionDecision(
                descriptorID: $0.id,
                rationaleCodes: ["explicit.request"]
            )
        }
        let runID = AgentRunID(rawValue: Self.uuid(1 + offset * 100))
        request = try AgentModelRequest(
            requestID: AgentRequestID(rawValue: Self.uuid(2 + offset * 100)),
            runID: runID,
            stepID: AgentStepID(rawValue: Self.uuid(3 + offset * 100)),
            selection: selection,
            compiledManifestDigest: StableDigest.sha256(Data("manifest-\(offset)".utf8)),
            messages: [
                AgentModelMessage(
                    role: .user,
                    content: userMessage ?? "hello",
                    isUntrustedData: false,
                    artifacts: messageArtifacts
                ),
            ],
            advertisedTools: advertisedTools,
            toolSelectionSnapshot: AgentToolSelectionSnapshot(
                selectorID: "selector.fixture",
                policyVersion: 1,
                inputDigest: StableDigest.sha256(Data("selection-\(offset)".utf8)),
                decisions: decisions
            ),
            generationParameters: AgentModelGenerationParameters(
                maximumOutputTokens: maximumOutputTokens,
                maximumContextTokens: maximumContextTokens,
                temperature: 0.7,
                topP: 1,
                topK: nil,
                repetitionPenalty: 1,
                thinkingMode: thinkingMode,
                seed: 7,
                outputBudgetMode: outputBudgetMode
            ),
            outputRequirement: .text
        )
        let payload = try SanitizedCanonicalJSON(
            value: request.authorizationPayload(),
            redaction: RedactionMetadata(
                classification: .sensitive,
                policyVersion: 1
            ),
            policyRevision: 1,
            attestationDigest: StableDigest.sha256(Data("attestation-\(offset)".utf8))
        )
        let grantAuthority: AgentAuthorityScope
        if location == .remote {
            grantAuthority = try AgentAuthorityScope(
                capabilities: AgentCapabilitySet([.externalCommunication]),
                destinations: [
                    try ExternalDestination(
                        kind: .modelProvider,
                        normalizedIdentity: remoteDestination
                            ?? "fixture.remote:\(descriptor.id.rawValue)"
                    ),
                ],
                dataCategories: [try AgentDataCategory(rawValue: "model.inference")]
            )
        } else {
            grantAuthority = .empty
        }
        ceiling = RunCapabilityCeiling(authority: grantAuthority)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: grantAuthority)
        context = try ModelPreparationContext(
            conversationID: ConversationID(rawValue: Self.uuid(4 + offset * 100)),
            modelPolicy: AgentModelPolicy(
                localOnly: true,
                allowedSelections: [selection],
                strategy: .pinned,
                requiredCapabilities: requiredCapabilities
            ),
            capabilityGrant: grant,
            authorizationPayload: payload,
            maximumRequestBytes: UInt64(max(4, payload.data.count)),
            maximumResponseBytes: 1_048_576,
            timeoutMilliseconds: 60_000
        )
        authority = try TrustedRunAuthority(
            runID: runID,
            ceiling: ceiling,
            policyRevision: 1
        )
    }

    func prepared(provider: ScriptedModelProvider? = nil) async throws -> PreparedAgentModelAttempt {
        let provider = provider ?? ScriptedModelProvider(
            descriptor: descriptor,
            capabilities: capabilities
        )
        return try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: request,
            context: context
        )
    }

    func authorized(
        provider: ScriptedModelProvider,
        policy: TestApprovalPolicyEngine = TestApprovalPolicyEngine(),
        clock: any AgentAuthorizationClock = FixedAuthorizationClock(),
        ledger: any ExternalOperationAttemptClaiming = TestAttemptLedger()
    ) async throws -> AuthorizedAgentModelAttempt {
        let prepared = try await self.prepared(provider: provider)
        return try await AgentModelAuthorizationBinder().authorizeLocal(
            prepared,
            approvalID: ApprovalID(rawValue: Self.uuid(5)),
            trustedRunAuthority: authority,
            at: AgentTimestamp(rawValue: 1_000),
            policyEngine: policy,
            clock: clock,
            attemptLedger: ledger
        )
    }

    static func tool(name: String = "lookup") throws -> AgentToolDescriptor {
        let schema = try JSONSchemaDocument(
            root: .object([
                "type": .string("object"),
                "properties": .object([
                    "q": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("q")]),
                "additionalProperties": .bool(false),
            ])
        )
        return try AgentToolDescriptor(
            id: AgentToolDescriptorID(
                logicalID: AgentToolLogicalID(providerID: "builtin", name: name),
                version: SemanticVersion("1.0.0")!,
                schemaDigest: schema.digest,
                trustRevision: "local-1"
            ),
            title: name,
            summary: "Look up a local value",
            inputSchema: schema,
            effects: [AgentEffect.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 5_000),
            retryPolicy: .never,
            idempotency: .pureRead,
            supportsProgress: false,
            supportsCancellation: true
        )
    }

    static func imageArtifact() throws -> ArtifactReference {
        try ArtifactReference(
            id: ArtifactID(rawValue: uuid(90)),
            contentDigest: StableDigest.sha256(Data("image".utf8)),
            byteCount: 5,
            mimeType: "image/png",
            semanticType: "user-image",
            provenance: ArtifactProvenance(providerID: "fixture"),
            createdAt: AgentTimestamp(rawValue: 1_000),
            retentionPolicy: .conversation,
            locator: ArtifactLocator(kind: .managedRelativePath, value: "aa/image"),
            sensitivity: .personalData,
            integrityStatus: .verified
        )
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }
}

enum ScriptedPreparationMode: Sendable {
    case valid
    case wrongSubject
}

struct ScriptedEmission: Sendable {
    let event: AgentModelEvent
    let responseBytes: UInt64

    init(_ event: AgentModelEvent, responseBytes: UInt64 = 1) {
        self.event = event
        self.responseBytes = responseBytes
    }
}

enum ScriptedTermination: Sendable {
    case completion(AgentModelBoundaryCompletion)
    case providerFailure(AgentFailure)
    case interruption(AgentModelInterruptionReason)
    case cancellation
    case unknownFailure
}

struct ScriptedModelProvider: AgentModelProvider {
    let descriptor: AgentModelProviderDescriptor
    let reportedCapabilities: AgentModelCapabilities
    let preparationMode: ScriptedPreparationMode
    let emissions: [ScriptedEmission]
    let termination: ScriptedTermination
    let invocationCounter: ScriptedInvocationCounter

    init(
        descriptor: AgentModelProviderDescriptor,
        capabilities: AgentModelCapabilities,
        preparationMode: ScriptedPreparationMode = .valid,
        emissions: [ScriptedEmission] = [],
        termination: ScriptedTermination? = nil,
        invocationCounter: ScriptedInvocationCounter = ScriptedInvocationCounter()
    ) {
        self.descriptor = descriptor
        reportedCapabilities = capabilities
        self.preparationMode = preparationMode
        self.emissions = emissions
        self.termination = termination ?? .completion(
            AgentModelBoundaryCompletion(outcome: .interrupted(nil))
        )
        self.invocationCounter = invocationCounter
    }

    func capabilities(for selection: AgentModelSelection) async throws -> AgentModelCapabilities {
        reportedCapabilities
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        switch preparationMode {
        case .valid:
            if descriptor.location == .remote {
                let plan = try ExternalOperationPlan(
                    kind: .modelProvider,
                    subjectID: descriptor.id.rawValue,
                    destination: try ExternalDestination(
                        kind: .modelProvider,
                        normalizedIdentity: "fixture.remote:\(descriptor.id.rawValue)"
                    ),
                    dataCategories: [try AgentDataCategory(rawValue: "model.inference")],
                    payloadDigest: context.authorizationPayload.fingerprint,
                    effects: [.externalCommunication],
                    requiredCapabilities: AgentCapabilitySet([.externalCommunication]),
                    maximumRequestBytes: context.maximumRequestBytes,
                    maximumResponseBytes: context.maximumResponseBytes,
                    timeoutMilliseconds: context.timeoutMilliseconds,
                    retryPolicy: .never,
                    idempotency: .nonIdempotent,
                    userPreview: "Send this conversation to the remote model"
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
            return try LocalAgentModelPreparation.prepare(
                request: request,
                context: context,
                provider: descriptor
            )
        case .wrongSubject:
            let plan = try ExternalOperationPlan(
                kind: .localPure,
                subjectID: "wrong.provider",
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

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        await invocationCounter.increment()
        for emission in emissions {
            try await emitter.emit(emission.event, responseBytes: emission.responseBytes)
        }
        switch termination {
        case .completion(let completion): return completion
        case .providerFailure(let failure): throw AgentModelProviderFailure(failure)
        case .interruption(let reason): throw AgentModelProviderInterruption(reason: reason)
        case .cancellation: throw CancellationError()
        case .unknownFailure: throw ScriptedModelError()
        }
    }
}

actor ScriptedInvocationCounter {
    private var value = 0

    func increment() { value += 1 }
    func count() -> Int { value }
}

struct ScriptedModelError: Error {}

struct FixedAuthorizationClock: AgentAuthorizationClock {
    let timestamp: AgentTimestamp

    init(_ rawValue: Int64 = 1_000) {
        timestamp = AgentTimestamp(rawValue: rawValue)
    }

    func now() async throws -> AgentTimestamp { timestamp }
}

actor TestAttemptLedger: ExternalOperationAttemptClaiming {
    private var claims: Set<StableDigest> = []

    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool {
        claims.insert(hop.fingerprint).inserted
    }
}

actor TestApprovalPolicyEngine: ApprovalPolicyEngine {
    nonisolated let policyVersion: UInt32 = 1
    private var isAuthorized = true

    nonisolated func evaluate(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?,
        feature: ApprovalFeatureState,
        interaction: ApprovalInteractionContext,
        candidateReceipts: [ApprovalReceipt],
        at timestamp: AgentTimestamp
    ) -> ApprovalPolicyEvaluation {
        fatalError("Model contract tests do not exercise approval presentation")
    }

    func bind(
        prepared: PreparedExternalOperationRequest,
        receipt: ApprovalReceipt,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        try await validateCurrentAuthorization(
            receipt: receipt,
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
        return try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedRunAuthority
        )
    }

    func bindLocalPolicy(
        prepared: PreparedExternalOperationRequest,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        let receipt = try ApprovalReceipt(
            id: approvalID,
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: policyVersion,
            decidedAt: timestamp
        )
        return try await bind(
            prepared: prepared,
            receipt: receipt,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }

    func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws {
        guard isAuthorized,
              receipt.policyVersion == policyVersion,
              receipt.isUsable(at: timestamp),
              trustedRunAuthority.validates(
                runID: prepared.runID,
                grant: prepared.capabilityGrant
              )
        else { throw AgentContractError.authorizationDenied }
        _ = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedRunAuthority
        )
    }

    func revoke() { isAuthorized = false }
}

actor RecordingModelEventSink: AgentModelRuntimeEventSink {
    private var storage: [AgentModelRuntimeEvent] = []

    func receive(_ event: AgentModelRuntimeEvent) { storage.append(event) }
    func events() -> [AgentModelRuntimeEvent] { storage }
}

func modelUsage(
    input: UInt64 = 10,
    output: UInt64 = 1,
    milliseconds: UInt64 = 10,
    memory: UInt64 = 100,
    cost: UInt64? = nil,
    currency: String? = nil
) throws -> AgentModelUsage {
    try AgentModelUsage(
        inputTokens: input,
        outputTokens: output,
        activeMilliseconds: milliseconds,
        peakMemoryBytes: memory,
        reportedCostMicros: cost,
        costCurrencyCode: currency
    )
}

func modelFailure(
    classification: AgentFailureClassification = .permanent,
    effect: ExternalEffectDisposition = .confirmedNone
) throws -> AgentFailure {
    try AgentFailure(
        code: classification == .potentiallySideEffecting
            ? "model.uncertain"
            : "model.fixture",
        classification: classification,
        safeMessage: "The scripted model failed.",
        retryAdvice: .never,
        externalEffect: effect,
        requiredUserAction: classification == .potentiallySideEffecting ? .reconcile : .none,
        redaction: RedactionMetadata(
            classification: .internalMetadata,
            policyVersion: 1
        )
    )
}
