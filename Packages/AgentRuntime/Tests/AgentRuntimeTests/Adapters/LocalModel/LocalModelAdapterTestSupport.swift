// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import LLMCore

struct LocalEngineScript: Sendable {
    enum Ending: Sendable {
        case finish
        case fail
        case failCancellation
        case failContract
        case waitForCancellation
    }
    let deltas: [EngineDelta]
    let ending: Ending

    init(_ deltas: [EngineDelta], ending: Ending = .finish) {
        self.deltas = deltas
        self.ending = ending
    }
}

struct LocalEngineCapture: Sendable, Equatable {
    let messages: [ChatTurn]
    let sampling: Sampling
}

struct LocalEngineFixtureError: Error {}

actor LocalAdapterScriptedEngine: LLMEngine {
    private var scripts: [LocalEngineScript]
    private var captures: [LocalEngineCapture] = []
    private var loads: [(LLMModel, LLMVariant, URL)] = []
    private var unloadCount = 0
    private var shouldFailLoad: Bool
    private var shouldBlockLoad = false
    private var loadEntered = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadReleasers: [CheckedContinuation<Void, Never>] = []

    init(scripts: [LocalEngineScript] = [], shouldFailLoad: Bool = false) {
        self.scripts = scripts
        self.shouldFailLoad = shouldFailLoad
    }

    func load(
        model: LLMModel,
        variant: LLMVariant,
        weightsDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        loads.append((model, variant, weightsDir))
        progress(0.5)
        if shouldBlockLoad {
            shouldBlockLoad = false
            loadEntered = true
            for waiter in loadWaiters { waiter.resume() }
            loadWaiters.removeAll()
            await withCheckedContinuation { loadReleasers.append($0) }
        }
        if shouldFailLoad {
            shouldFailLoad = false
            throw LocalEngineFixtureError()
        }
        progress(1)
    }

    func unload() async { unloadCount += 1 }

    nonisolated func generate(
        messages: [ChatTurn],
        params: Sampling
    ) -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let script = await self.begin(messages: messages, sampling: params)
                do {
                    for delta in script.deltas {
                        try Task.checkCancellation()
                        continuation.yield(delta)
                    }
                    switch script.ending {
                    case .finish:
                        continuation.finish()
                    case .fail:
                        continuation.finish(throwing: LocalEngineFixtureError())
                    case .failCancellation:
                        continuation.finish(throwing: CancellationError())
                    case .failContract:
                        continuation.finish(
                            throwing: AgentContractError.invalidEventSequence("scripted contract failure")
                        )
                    case .waitForCancellation:
                        while true { try await Task.sleep(nanoseconds: 50_000_000) }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func begin(messages: [ChatTurn], sampling: Sampling) -> LocalEngineScript {
        captures.append(LocalEngineCapture(messages: messages, sampling: sampling))
        return scripts.isEmpty ? LocalEngineScript([]) : scripts.removeFirst()
    }

    func enqueue(_ script: LocalEngineScript) { scripts.append(script) }
    func recordedCaptures() -> [LocalEngineCapture] { captures }
    func recordedLoadCount() -> Int { loads.count }
    func recordedUnloadCount() -> Int { unloadCount }
    func blockNextLoad() { shouldBlockLoad = true }

    func waitForBlockedLoad() async {
        if loadEntered { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func releaseBlockedLoad() {
        let releasers = loadReleasers
        loadReleasers.removeAll()
        for releaser in releasers { releaser.resume() }
    }
}

struct LocalAdapterHarness {
    let descriptor: AgentModelProviderDescriptor
    let registration: LocalModelRegistration
    let provider: LocalModelProvider
    let engine: LocalAdapterScriptedEngine
    let request: AgentModelRequest
    let context: ModelPreparationContext
    let authority: TrustedRunAuthority

    static func make(
        model: LLMModel = LLMCatalog.bonsai8b,
        variant: LLMVariant? = nil,
        messages: [AgentModelMessage]? = nil,
        tools: [AgentToolDescriptor] = [],
        output: AgentOutputRequirement = .text,
        thinking: AgentModelThinkingMode = .automatic,
        topK: UInt32? = nil,
        resolver: any LocalModelArtifactBytesResolving =
            UnavailableLocalModelArtifactResolver(),
        configuration: LocalModelAdapterConfiguration = try! LocalModelAdapterConfiguration(
            nowMilliseconds: { 1_500 }
        ),
        scripts: [LocalEngineScript] = [],
        shouldFailLoad: Bool = false,
        offset: Int = 0
    ) throws -> Self {
        let version = SemanticVersion("1.0.0")!
        let descriptor = AgentModelProviderDescriptor(
            id: try AgentModelProviderID("local.llmcore.\(offset)"),
            adapterVersion: version,
            capabilityVersion: version,
            location: .onDevice
        )
        let registration = try LocalModelRegistration(
            providerID: descriptor.id,
            capabilityVersion: version,
            model: model,
            variant: variant ?? model.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/mobilellm-agent-model-\(offset)"),
            maximumOutputTokens: 128
        )
        let engine = LocalAdapterScriptedEngine(
            scripts: scripts,
            shouldFailLoad: shouldFailLoad
        )
        let driver = try LLMCoreModelResidencyDriver(
            engine: engine,
            registrations: [registration]
        )
        let provider = try LocalModelProvider(
            descriptor: descriptor,
            residencyDriver: driver,
            artifactResolver: resolver,
            configuration: configuration
        )
        let decisions = try tools.map {
            try AgentToolSelectionDecision(
                descriptorID: $0.id,
                rationaleCodes: ["explicit.request"]
            )
        }
        let runID = AgentRunID(rawValue: ModelFixture.uuid(700 + offset * 10))
        let request = try AgentModelRequest(
            requestID: AgentRequestID(rawValue: ModelFixture.uuid(701 + offset * 10)),
            runID: runID,
            stepID: AgentStepID(rawValue: ModelFixture.uuid(702 + offset * 10)),
            selection: registration.selection,
            compiledManifestDigest: StableDigest.sha256(Data("local-manifest-\(offset)".utf8)),
            messages: messages ?? [
                AgentModelMessage(role: .user, content: "hello", isUntrustedData: false),
            ],
            advertisedTools: tools,
            toolSelectionSnapshot: AgentToolSelectionSnapshot(
                selectorID: "selector.local-adapter",
                policyVersion: 1,
                inputDigest: StableDigest.sha256(Data("local-selection-\(offset)".utf8)),
                decisions: decisions
            ),
            generationParameters: AgentModelGenerationParameters(
                maximumOutputTokens: 128,
                maximumContextTokens: min(4_096, registration.capabilities.maximumContextTokens),
                temperature: 0.25,
                topP: 0.9,
                topK: topK,
                repetitionPenalty: 1.1,
                thinkingMode: thinking,
                seed: 42
            ),
            outputRequirement: output
        )
        let payload = try SanitizedCanonicalJSON(
            value: request.authorizationPayload(),
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1),
            policyRevision: 1,
            attestationDigest: StableDigest.sha256(Data("local-attestation-\(offset)".utf8))
        )
        let ceiling = RunCapabilityCeiling(authority: .empty)
        let authority = try TrustedRunAuthority(
            runID: runID,
            ceiling: ceiling,
            policyRevision: 1
        )
        let context = try ModelPreparationContext(
            conversationID: ConversationID(rawValue: ModelFixture.uuid(703 + offset * 10)),
            modelPolicy: AgentModelPolicy(
                localOnly: true,
                allowedSelections: [registration.selection],
                strategy: .pinned,
                requiredCapabilities: AgentModelCapabilitySet([])
            ),
            capabilityGrant: StepCapabilityGrant(runCeiling: ceiling, authority: .empty),
            authorizationPayload: payload,
            maximumRequestBytes: UInt64(payload.data.count),
            maximumResponseBytes: 2 * 1_024 * 1_024,
            timeoutMilliseconds: 60_000
        )
        return Self(
            descriptor: descriptor,
            registration: registration,
            provider: provider,
            engine: engine,
            request: request,
            context: context,
            authority: authority
        )
    }

    func execute(
        sink: (any AgentModelRuntimeEventSink)? = nil,
        load: Bool = true
    ) async throws -> AgentModelExecutionResult {
        if load { try await provider.residencyDriver.load(selection: request.selection) }
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: request,
            context: context
        )
        let authorized = try await AgentModelAuthorizationBinder().authorizeLocal(
            prepared,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(799)),
            trustedRunAuthority: authority,
            at: AgentTimestamp(rawValue: 1_000),
            policyEngine: TestApprovalPolicyEngine(),
            clock: FixedAuthorizationClock(),
            attemptLedger: TestAttemptLedger()
        )
        return try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )
    }
}

func localStats(
    prompt: Int = 10,
    generated: Int = 3,
    memory: Int64 = 1_000,
    reason: StopReason = .eos
) -> Stats {
    Stats(
        promptTokens: prompt,
        genTokens: generated,
        promptTPS: 50,
        tokensPerSecond: 20,
        peakMemoryBytes: memory,
        stopReason: reason
    )
}
