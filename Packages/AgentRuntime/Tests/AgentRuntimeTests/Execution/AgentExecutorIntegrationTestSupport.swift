// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation

enum ExecutorTestID {
    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012x", value))!
    }

    static func request(_ value: Int) -> AgentRequestID {
        AgentRequestID(rawValue: uuid(1_000 + value))
    }

    static func run(_ value: Int) -> AgentRunID {
        AgentRunID(rawValue: uuid(2_000 + value))
    }

    static func conversation(_ value: Int) -> ConversationID {
        ConversationID(rawValue: uuid(3_000 + value))
    }

    static func turn(_ value: Int) -> UserTurnID {
        UserTurnID(rawValue: uuid(4_000 + value))
    }

    static func command(_ value: Int) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(5_000 + value))
    }

    static func invocation(_ value: Int) -> ToolInvocationID {
        ToolInvocationID(rawValue: uuid(6_000 + value))
    }
}

struct ExecutorTestModelDefinition: Sendable {
    let descriptor: AgentModelProviderDescriptor
    let selection: AgentModelSelection
    let capabilities: AgentModelCapabilities

    init(
        offset: Int,
        toolCallingMode: ModelToolCallingMode = .nativeStructured,
        additionalCapabilities: [AgentModelCapability] = []
    ) throws {
        let version = SemanticVersion("1.0.0")!
        let providerID = try AgentModelProviderID("local.executor-test.\(offset)")
        descriptor = AgentModelProviderDescriptor(
            id: providerID,
            adapterVersion: version,
            capabilityVersion: version,
            location: .onDevice
        )
        selection = AgentModelSelection(
            providerID: providerID,
            modelID: try AgentModelID("executor-test-model"),
            variantID: try AgentModelVariantID("executor-test-variant"),
            capabilityVersion: version
        )
        var features: [AgentModelCapability] = [.reasoning]
        switch toolCallingMode {
        case .nativeStructured: features.append(.nativeToolCalling)
        case .textDialect: features.append(.textToolDialect)
        case .unavailable: break
        }
        features.append(contentsOf: additionalCapabilities)
        capabilities = try AgentModelCapabilities(
            maximumContextTokens: 4_096,
            maximumOutputTokens: 1_024,
            features: AgentModelCapabilitySet(features),
            toolCallingMode: toolCallingMode,
            cancellationGranularity: .token,
            resourceConstraints: ModelResourceConstraints(
                maximumConcurrentAttempts: 1,
                requiresResidentModel: true,
                requiresDrainBeforeSwitch: true
            ),
            reportsTokenUsage: true,
            reportsCost: false
        )
    }
}

struct FixedExecutorClock: AgentExecutionClock, Sendable {
    let timestamp: AgentTimestamp

    init(_ rawValue: Int64 = 50_000) {
        timestamp = AgentTimestamp(rawValue: rawValue)
    }

    func now() async throws -> AgentTimestamp { timestamp }

    func sleep(milliseconds _: UInt64) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// A wall clock whose first `now()` read is ahead of every later read — exercising the runtime's
/// elapsed-time overflow/regression fallbacks without a real monotonic clock.
actor RegressingExecutorClock: AgentExecutionClock {
    private let first: Int64
    private let later: Int64
    private var reads = 0

    init(first: Int64, later: Int64) {
        self.first = first
        self.later = later
    }

    func now() async throws -> AgentTimestamp {
        reads += 1
        return AgentTimestamp(rawValue: reads == 1 ? first : later)
    }

    func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

final class DeterministicExecutorArtifactNames: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func nextID() -> ArtifactID {
        lock.withLock {
            counter += 1
            return ArtifactID(rawValue: ExecutorTestID.uuid(100_000 + counter))
        }
    }

    func nextName() -> String {
        lock.withLock {
            counter += 1
            return "executor-test-temporary-\(counter)"
        }
    }
}

struct ExecutorTestHarness {
    let executor: DurableAgentExecutor
    let repository: SQLiteRunJournal
    let payloadStore: ContentAddressedExecutionPayloadStore
    let residencyDriver: ScriptedModelResidencyDriver
    let request: AgentRequest
    let frozenInputs: FrozenAgentRunInputs
    let model: ExecutorTestModelDefinition
    let databaseURL: URL
    let attestor: LocalSanitizationAttestor
    let logger: ExecutorTestLogger

    init(
        offset: Int,
        provider: any AgentModelProvider,
        model: ExecutorTestModelDefinition,
        toolDescriptors: [AgentToolDescriptor] = [],
        tools: any ExecutableToolCatalog = EmptyExecutableToolCatalog(),
        capabilityCeiling: RunCapabilityCeiling = .init(authority: .empty),
        availableToolCapabilities: AgentCapabilitySet = .init([]),
        toolPolicyEnabled: Bool? = nil,
        explicitlyRequestedToolIDs: [AgentToolLogicalID] = [],
        outputRequirement: AgentOutputRequirement = .text,
        instruction: String = "Answer the user's request.",
        clock: any AgentExecutionClock = FixedExecutorClock(),
        budget suppliedBudget: AgentBudget? = nil,
        policyEngine suppliedPolicyEngine: (any ApprovalPolicyEngine)? = nil,
        repositoryFactory: ((SQLiteRunJournal) -> any RuntimeRepository)? = nil
    ) throws {
        self.model = model
        let runID = ExecutorTestID.run(offset)
        let conversationID = ExecutorTestID.conversation(offset)
        let userTurnID = ExecutorTestID.turn(offset)
        let budget = try suppliedBudget ?? AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: 4_096,
            outputTokens: 6_144,
            peakMemoryBytes: 1_073_741_824
        )
        request = try AgentRequest(
            id: ExecutorTestID.request(offset),
            runID: runID,
            conversationID: conversationID,
            userTurnID: userTurnID,
            role: "assistant",
            instruction: instruction,
            outputRequirement: outputRequirement,
            modelPolicy: AgentModelPolicy(
                localOnly: true,
                allowedSelections: [model.selection],
                strategy: .pinned,
                requiredCapabilities: .init([])
            ),
            capabilityCeiling: capabilityCeiling,
            budget: budget,
            provenance: AgentRequestProvenance(source: .user)
        )
        let logicalIDs = toolDescriptors.map(\.id.logicalID)
        frozenInputs = try FrozenAgentRunInputs(
            modelSelection: model.selection,
            generationParameters: .standard,
            contextBudget: ContextTokenBudget(
                maximumContextTokens: 4_096,
                reservedOutputTokens: 1_024,
                maximumToolSchemaTokens: 1_024
            ),
            baseSystem: BaseSystemContextSource(
                revision: "executor-test-v1",
                content: "Follow the user's instructions and return one normalized action."
            ),
            currentUser: CurrentUserContextSource(
                userTurnID: userTurnID,
                revision: "executor-test-v1",
                content: "Please provide a concise answer."
            ),
            toolCatalog: ToolCatalogSnapshot(revision: 1, descriptors: toolDescriptors),
            toolPolicy: ConversationToolPolicy(
                masterEnabled: toolPolicyEnabled ?? !toolDescriptors.isEmpty,
                allowedToolIDs: logicalIDs,
                pinnedToolIDs: logicalIDs,
                selectionPolicyVersion: 1,
                materializedFromGlobalTemplate: false
            ),
            availableToolCapabilities: availableToolCapabilities,
            explicitlyRequestedToolIDs: explicitlyRequestedToolIDs,
            contextPolicyVersion: 1,
            approvalPolicyVersion: 1
        )

        let unique = "\(offset)-\(UUID().uuidString)"
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobilellm-executor-\(unique).sqlite")
        repository = SQLiteRunJournal(databaseURL: databaseURL)
        let artifactRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobilellm-executor-artifacts-\(unique)", isDirectory: true)
        let names = DeterministicExecutorArtifactNames()
        let artifactStore = try ContentAddressedArtifactStore(
            configuration: ArtifactStoreConfiguration(
                rootURL: artifactRoot,
                excludeFromBackup: false,
                verifyPlatformProtection: false
            ),
            clock: { AgentTimestamp(rawValue: 50_000) },
            idGenerator: { names.nextID() },
            temporaryNameGenerator: { names.nextName() }
        )
        payloadStore = ContentAddressedExecutionPayloadStore(store: artifactStore)
        residencyDriver = ScriptedModelResidencyDriver()
        attestor = try executorTestAttestor(offset: offset)
        logger = ExecutorTestLogger()
        let policyEngine = try suppliedPolicyEngine ?? DefaultApprovalPolicyEngine(
            policyVersion: 1,
            sanitizationValidator: attestor
        )
        let runtimeRepository: any RuntimeRepository = repositoryFactory?(repository) ?? repository
        executor = DurableAgentExecutor(
            repository: runtimeRepository,
            payloadStore: payloadStore,
            inputFreezer: StaticAgentRunInputFreezer(inputs: frozenInputs),
            modelProviders: try StaticAgentModelProviderCatalog(providers: [provider]),
            tools: tools,
            policyEngine: policyEngine,
            sanitizer: attestor,
            residencyDriver: residencyDriver,
            clock: clock,
            logger: logger
        )
    }
}

actor ExecutorTestLogger: AgentExecutionLogging {
    struct Entry: Sendable {
        let code: String
        let metadata: [String: String]
    }

    private var entries: [Entry] = []

    func record(code: String, metadata: [String: String]) async {
        entries.append(Entry(code: code, metadata: metadata))
    }

    func snapshot() -> [Entry] { entries }
}

func executorTestAttestor(offset: Int) throws -> LocalSanitizationAttestor {
    try LocalSanitizationAttestor(
        key: Data(repeating: UInt8(truncatingIfNeeded: offset + 37), count: 32),
        policyRevision: 1
    )
}

struct FixedCompletionModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let completion: AgentModelCompletion
    let invocationCounter: ScriptedInvocationCounter
    let lifecycle: ExecutorModelLifecycleProbe

    init(
        model: ExecutorTestModelDefinition,
        answer: String,
        invocationCounter: ScriptedInvocationCounter = ScriptedInvocationCounter(),
        lifecycle: ExecutorModelLifecycleProbe = ExecutorModelLifecycleProbe()
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: answer)),
            usage: modelUsage(input: 12, output: 3, milliseconds: 7, memory: 128)
        )
        self.invocationCounter = invocationCounter
        self.lifecycle = lifecycle
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        await lifecycle.recordCapabilities()
        return capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        await lifecycle.recordPreparation()
        return try LocalAgentModelPreparation.prepare(
            request: request,
            context: context,
            provider: descriptor
        )
    }

    func generate(
        _: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        await lifecycle.recordGeneration()
        await invocationCounter.increment()
        try await emitter.emit(.completed(completion), responseBytes: 16)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

actor ExecutorModelLifecycleProbe {
    private var capabilitiesCount = 0
    private var preparationCount = 0
    private var generationCount = 0

    func recordCapabilities() { capabilitiesCount += 1 }
    func recordPreparation() { preparationCount += 1 }
    func recordGeneration() { generationCount += 1 }

    func snapshot() -> (capabilities: Int, preparations: Int, generations: Int) {
        (capabilitiesCount, preparationCount, generationCount)
    }
}

actor BlockingModelGate {
    private var entered = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hasEntered() -> Bool { entered }

    func suspendUntilReleased() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

struct BlockingCompletionModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let completion: AgentModelCompletion
    let gate: BlockingModelGate
    let invocationCounter: ScriptedInvocationCounter

    init(
        model: ExecutorTestModelDefinition,
        answer: String,
        gate: BlockingModelGate,
        invocationCounter: ScriptedInvocationCounter = ScriptedInvocationCounter()
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: answer)),
            usage: modelUsage(input: 10, output: 2, milliseconds: 5, memory: 64)
        )
        self.gate = gate
        self.invocationCounter = invocationCounter
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        await invocationCounter.increment()
        await gate.suspendUntilReleased()
        try Task.checkCancellation()
        try await emitter.emit(.completed(completion), responseBytes: 16)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

struct EphemeralCompletionModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let completion: AgentModelCompletion
    let gate: BlockingModelGate
    let reasoningDelta: String
    let answerDelta: String
    let escapedEmitterProbe: EscapedModelEmitterProbe?

    init(
        model: ExecutorTestModelDefinition,
        answer: String,
        reasoningDelta: String,
        gate: BlockingModelGate = BlockingModelGate(),
        escapedEmitterProbe: EscapedModelEmitterProbe? = nil
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: answer)),
            usage: modelUsage(input: 13, output: 4, milliseconds: 8, memory: 96)
        )
        self.gate = gate
        self.reasoningDelta = reasoningDelta
        answerDelta = answer
        self.escapedEmitterProbe = escapedEmitterProbe
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        await gate.suspendUntilReleased()
        try Task.checkCancellation()
        try await emitter.emit(.reasoningDelta(reasoningDelta), responseBytes: 4)
        try await emitter.emit(.usage(completion.usage), responseBytes: 2)
        try await emitter.emit(.answerDelta(answerDelta), responseBytes: 4)
        try await emitter.emit(.completed(completion), responseBytes: 8)
        await escapedEmitterProbe?.capture(emitter)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

actor EscapedModelEmitterProbe {
    private var emitter: AgentModelBoundaryEmitter?

    func capture(_ emitter: AgentModelBoundaryEmitter) { self.emitter = emitter }

    func emitLateReasoning(_ value: String) async -> Bool {
        guard let emitter else { return false }
        do {
            try await emitter.emit(.reasoningDelta(value), responseBytes: 1)
            return true
        } catch {
            return false
        }
    }
}

actor MalformedThenValidModelScript {
    private var requests: [AgentModelRequest] = []

    func begin(_ request: AgentModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct MalformedThenValidModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let malformedCompletion: AgentModelCompletion
    let conflictingCompletion: AgentModelCompletion
    let validCompletion: AgentModelCompletion
    let script: MalformedThenValidModelScript

    init(
        model: ExecutorTestModelDefinition,
        answer: String,
        script: MalformedThenValidModelScript = MalformedThenValidModelScript()
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        malformedCompletion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Malformed provisional answer")),
            usage: modelUsage(input: 5, output: 2, milliseconds: 3, memory: 32)
        )
        conflictingCompletion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Conflicting boundary answer")),
            usage: modelUsage(input: 5, output: 2, milliseconds: 3, memory: 32)
        )
        validCompletion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: answer)),
            usage: modelUsage(input: 8, output: 3, milliseconds: 4, memory: 48)
        )
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let attempt = await script.begin(request)
        if attempt == 1 {
            try await emitter.emit(.completed(malformedCompletion), responseBytes: 8)
            return AgentModelBoundaryCompletion(outcome: .completed(conflictingCompletion))
        }
        try await emitter.emit(.completed(validCompletion), responseBytes: 8)
        return AgentModelBoundaryCompletion(outcome: .completed(validCompletion))
    }
}

actor SequencedModelOutcomeScript {
    private let outcomes: [AgentModelAttemptOutcome]
    private var requests: [AgentModelRequest] = []

    init(outcomes: [AgentModelAttemptOutcome]) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
    }

    func next(for request: AgentModelRequest) -> AgentModelAttemptOutcome {
        requests.append(request)
        return outcomes[min(requests.count - 1, outcomes.count - 1)]
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct SequencedModelOutcomeProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let script: SequencedModelOutcomeScript
    let lifecycle: ExecutorModelLifecycleProbe

    init(
        model: ExecutorTestModelDefinition,
        outcomes: [AgentModelAttemptOutcome]
    ) {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        script = SequencedModelOutcomeScript(outcomes: outcomes)
        lifecycle = ExecutorModelLifecycleProbe()
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        await lifecycle.recordCapabilities()
        return capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        await lifecycle.recordPreparation()
        return try LocalAgentModelPreparation.prepare(
            request: request,
            context: context,
            provider: descriptor
        )
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        await lifecycle.recordGeneration()
        let outcome = await script.next(for: request)
        switch outcome {
        case .completed(let completion):
            try await emitter.emit(.completed(completion), responseBytes: 8)
        case .failed(let failure):
            try await emitter.emit(.failed(failure), responseBytes: 8)
        case .interrupted:
            break
        }
        return AgentModelBoundaryCompletion(outcome: outcome)
    }
}

actor PauseThenAnswerModelScript {
    private var requests: [AgentModelRequest] = []
    private var firstAttemptEntered = false

    func begin(_ request: AgentModelRequest) -> Int {
        requests.append(request)
        if requests.count == 1 { firstAttemptEntered = true }
        return requests.count
    }

    func hasStartedFirstAttempt() -> Bool { firstAttemptEntered }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct PauseThenAnswerModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let completion: AgentModelCompletion
    let script: PauseThenAnswerModelScript

    init(
        model: ExecutorTestModelDefinition,
        answer: String,
        script: PauseThenAnswerModelScript = PauseThenAnswerModelScript()
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: answer)),
            usage: modelUsage(input: 9, output: 2, milliseconds: 5, memory: 64)
        )
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let attempt = await script.begin(request)
        if attempt == 1 {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        try await emitter.emit(.completed(completion), responseBytes: 8)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

actor ToolSequenceModelScript {
    enum Mode: Sendable {
        case toolThenAnswer
        case repeatTool
        case repeatOnceThenAnswer
    }

    let mode: Mode
    private var requests: [AgentModelRequest] = []

    init(mode: Mode = .toolThenAnswer) { self.mode = mode }

    func nextAction(
        request: AgentModelRequest,
        call: ProposedToolCall,
        answer: AgentAnswer
    ) -> AgentAction {
        requests.append(request)
        return switch (mode, requests.count) {
        case (.toolThenAnswer, 1),
             (.repeatOnceThenAnswer, 1),
             (.repeatOnceThenAnswer, 2),
             (.repeatTool, _): .callTools([call])
        default: .finalAnswer(answer)
        }
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct ToolSequenceModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let call: ProposedToolCall
    let answer: AgentAnswer
    let script: ToolSequenceModelScript

    init(
        model: ExecutorTestModelDefinition,
        call: ProposedToolCall,
        answer: String,
        script: ToolSequenceModelScript = ToolSequenceModelScript()
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        self.call = call
        self.answer = try AgentAnswer(text: answer)
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let action = await script.nextAction(request: request, call: call, answer: answer)
        let completion = try AgentModelCompletion(
            action: action,
            usage: modelUsage(input: 11, output: 2, milliseconds: 6, memory: 80)
        )
        try await emitter.emit(.completed(completion), responseBytes: 12)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

/// Executes the initial tool-selection pass immediately, then blocks every tool-free synthesis
/// pass until the test releases it. This lets pause/resume recovery be exercised at a real model
/// boundary without changing runtime visibility or injecting journal-only behavior.
struct GatedSynthesisToolSequenceModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let call: ProposedToolCall
    let answer: AgentAnswer
    let script: ToolSequenceModelScript
    let gate: BlockingModelGate

    init(
        model: ExecutorTestModelDefinition,
        call: ProposedToolCall,
        answer: String,
        script: ToolSequenceModelScript = ToolSequenceModelScript(),
        gate: BlockingModelGate
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        self.call = call
        self.answer = try AgentAnswer(text: answer)
        self.script = script
        self.gate = gate
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let action = await script.nextAction(request: request, call: call, answer: answer)
        if case .finalAnswer = action {
            await gate.suspendUntilReleased()
            try Task.checkCancellation()
        }
        let completion = try AgentModelCompletion(
            action: action,
            usage: modelUsage(input: 11, output: 2, milliseconds: 6, memory: 80)
        )
        try await emitter.emit(.completed(completion), responseBytes: 12)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

actor BatchToolSequenceModelScript {
    private var requests: [AgentModelRequest] = []

    func nextAction(
        request: AgentModelRequest,
        calls: [ProposedToolCall],
        answer: AgentAnswer
    ) -> AgentAction {
        requests.append(request)
        return requests.count == 1 ? .callTools(calls) : .finalAnswer(answer)
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct BatchToolSequenceModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let calls: [ProposedToolCall]
    let answer: AgentAnswer
    let script: BatchToolSequenceModelScript

    init(
        model: ExecutorTestModelDefinition,
        calls: [ProposedToolCall],
        answer: String,
        script: BatchToolSequenceModelScript = BatchToolSequenceModelScript()
    ) throws {
        precondition(!calls.isEmpty)
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        self.calls = calls
        self.answer = try AgentAnswer(text: answer)
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let action = await script.nextAction(request: request, calls: calls, answer: answer)
        let completion = try AgentModelCompletion(
            action: action,
            usage: modelUsage(input: 13, output: 3, milliseconds: 7, memory: 96)
        )
        try await emitter.emit(.completed(completion), responseBytes: 16)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

actor UserInputModelScript {
    private var requests: [AgentModelRequest] = []

    func nextAction(
        request: AgentModelRequest,
        interaction: UserInputRequest,
        answer: AgentAnswer
    ) -> AgentAction {
        requests.append(request)
        return requests.count == 1 ? .requestUserInput(interaction) : .finalAnswer(answer)
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct UserInputThenAnswerModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let interaction: UserInputRequest
    let answer: AgentAnswer
    let script: UserInputModelScript

    init(
        model: ExecutorTestModelDefinition,
        runID: AgentRunID,
        interactionID: InteractionRequestID,
        answer: String,
        script: UserInputModelScript = UserInputModelScript()
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        interaction = try UserInputRequest(
            id: interactionID,
            runID: runID,
            prompt: "Which option should I use?",
            responseSchema: JSONSchemaDocument(root: .object([
                "type": .string("string"),
                "enum": .array([.string("A"), .string("B")]),
            ])),
            creationStateVersion: 1
        )
        self.answer = try AgentAnswer(text: answer)
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let action = await script.nextAction(
            request: request,
            interaction: interaction,
            answer: answer
        )
        let completion = try AgentModelCompletion(
            action: action,
            usage: modelUsage(input: 7, output: 2, milliseconds: 4, memory: 48)
        )
        try await emitter.emit(.completed(completion), responseBytes: 8)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

actor MultiUserInputModelScript {
    private var requests: [AgentModelRequest] = []

    func nextAction(
        request: AgentModelRequest,
        interactions: [UserInputRequest],
        answer: AgentAnswer
    ) -> AgentAction {
        requests.append(request)
        let index = requests.count - 1
        if index < interactions.count {
            return .requestUserInput(interactions[index])
        }
        return .finalAnswer(answer)
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

struct MultiUserInputThenAnswerModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let interactions: [UserInputRequest]
    let answer: AgentAnswer
    let script: MultiUserInputModelScript

    init(
        model: ExecutorTestModelDefinition,
        runID: AgentRunID,
        interactionIDs: [InteractionRequestID],
        answer: String,
        script: MultiUserInputModelScript = MultiUserInputModelScript()
    ) throws {
        precondition(!interactionIDs.isEmpty)
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        interactions = try interactionIDs.enumerated().map { index, id in
            try UserInputRequest(
                id: id,
                runID: runID,
                prompt: "Choose option \(index + 1).",
                responseSchema: JSONSchemaDocument(root: .object([
                    "type": .string("string"),
                    "enum": .array([.string("A"), .string("B")]),
                ])),
                creationStateVersion: 1
            )
        }
        self.answer = try AgentAnswer(text: answer)
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let action = await script.nextAction(
            request: request,
            interactions: interactions,
            answer: answer
        )
        let completion = try AgentModelCompletion(
            action: action,
            usage: modelUsage(input: 7, output: 2, milliseconds: 4, memory: 48)
        )
        try await emitter.emit(.completed(completion), responseBytes: 8)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

struct ExecutorTestToolDefinition: Sendable {
    let descriptor: AgentToolDescriptor
    let destination: ExternalDestination?
    let dataCategories: [AgentDataCategory]
    let idempotencyKey: ExternalIdempotencyKey?

    init(
        name: String,
        effect: AgentEffect = .localPure,
        retryPolicy: ExternalRetryPolicy = .never,
        idempotency: ExternalIdempotency = .pureRead,
        supportsProgress: Bool = false,
        destinationKind: ExternalDestination.Kind? = nil
    ) throws {
        let input = try JSONSchemaDocument(
            root: .object([
                "type": .string("object"),
                "properties": .object(["q": .object(["type": .string("string")])]),
                "required": .array([.string("q")]),
                "additionalProperties": .bool(false),
            ])
        )
        let logicalID = try AgentToolLogicalID(providerID: "executor-test", name: name)
        let required = AgentCapabilitySet(effect.minimumCapability.map { [$0] } ?? [])
        descriptor = try AgentToolDescriptor(
            id: AgentToolDescriptorID(
                logicalID: logicalID,
                version: SemanticVersion("1.0.0")!,
                schemaDigest: input.digest,
                trustRevision: "executor-test-v1"
            ),
            title: "Executor Test \(name)",
            summary: "A deterministic integration-test tool.",
            inputSchema: input,
            effects: [effect],
            requiredCapabilities: required,
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 5_000),
            retryPolicy: retryPolicy,
            idempotency: idempotency,
            supportsProgress: supportsProgress,
            supportsCancellation: true
        )
        switch effect {
        case .localPure:
            destination = nil
            dataCategories = []
        case .localRead, .localWrite:
            destination = try ExternalDestination(
                kind: destinationKind ?? .fileReference,
                normalizedIdentity: "executor-local-file.\(name)"
            )
            dataCategories = []
        case .privateDataRead:
            destination = try ExternalDestination(
                kind: destinationKind ?? .privateDataStore,
                normalizedIdentity: "executor-private-store.\(name)"
            )
            dataCategories = [try AgentDataCategory(rawValue: "user.private")]
        default:
            destination = try ExternalDestination(
                kind: destinationKind ?? .networkEndpoint,
                normalizedIdentity: "https://executor.test/\(name)"
            )
            dataCategories = [try AgentDataCategory(rawValue: "query.text")]
        }
        idempotencyKey = idempotency == .idempotencyKeyRequired
            ? .derive(components: [Data("executor-test:\(name)".utf8)])
            : nil
    }

    func call(offset: Int, query: String = "value") throws -> ProposedToolCall {
        ProposedToolCall(
            invocationID: ExecutorTestID.invocation(offset),
            toolID: descriptor.id.logicalID,
            arguments: try CanonicalJSON(.object(["q": .string(query)]))
        )
    }

    func ceiling() throws -> RunCapabilityCeiling {
        RunCapabilityCeiling(authority: try AgentAuthorityScope(
            capabilities: descriptor.requiredCapabilities,
            destinations: destination.map { [$0] } ?? [],
            dataCategories: dataCategories
        ))
    }
}

actor ExecutorTestToolCounter {
    private var preparationCount = 0
    private var executionCount = 0
    private var boundaryCount = 0

    func prepared() { preparationCount += 1 }
    func executed() -> Int {
        executionCount += 1
        return executionCount
    }
    func crossedBoundary() -> Int {
        boundaryCount += 1
        return boundaryCount
    }
    func snapshot() -> (preparations: Int, executions: Int, boundaries: Int) {
        (preparationCount, executionCount, boundaryCount)
    }
}

enum ExecutorTestToolBehavior: Sendable {
    case complete(String)
    case completeEmptyText
    case completeWithoutBoundary(String)
    case failWithoutBoundary(AgentFailure)
    case throwContractBeforeBoundary(AgentContractError)
    case throwCancellationBeforeBoundary
    case completeCrossingBoundary(String)
    case progressThenComplete(ToolExecutionProgress, String)
    case blockedProgressThenComplete(BlockingModelGate, ToolExecutionProgress, String)
    case blockFirstAttemptBeforeBoundaryThenComplete(String)
    case blockFirstAttemptInsideBoundaryThenComplete(String)
    case failAfterBoundary(AgentFailure)
    case throwAcrossBoundary
    case throwAcrossBoundaryWithDiagnostic(String)
    case throwOnceThenComplete(String)
    case throwAttemptsThenComplete(Int, String)
    case failAfterBoundaryThenBlockStream(BlockingModelGate, AgentFailure)
}

struct ExecutorTestTool: ToolV2, Sendable {
    let descriptor: AgentToolDescriptor
    let definition: ExecutorTestToolDefinition
    let behavior: ExecutorTestToolBehavior
    let counter: ExecutorTestToolCounter

    init(
        definition: ExecutorTestToolDefinition,
        behavior: ExecutorTestToolBehavior,
        counter: ExecutorTestToolCounter = ExecutorTestToolCounter()
    ) {
        descriptor = definition.descriptor
        self.definition = definition
        self.behavior = behavior
        self.counter = counter
    }

    func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        await counter.prepared()
        let isLocal = descriptor.effects == [.localPure]
        let plan = try ExternalOperationPlan(
            kind: isLocal ? .localPure : .tool,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            destination: definition.destination,
            dataCategories: definition.dataCategories,
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: UInt64(max(4, request.sanitizedArguments.data.count)),
            maximumResponseBytes: 1_024,
            timeoutMilliseconds: descriptor.timeoutPolicy.maximumMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            idempotencyKey: definition.idempotencyKey,
            userPreview: isLocal ? "" : "Run \(descriptor.title) for this exact query.",
            descriptorID: descriptor.id.description,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let plan = prepared.prepared.externalOperation.plan
                    let executionNumber = await counter.executed()
                    let isLocalPure = plan.effects.allSatisfy { $0 == .localPure }
                    let observation = try ExternalOperationObservation(
                        destination: plan.destination,
                        dataCategories: plan.dataCategories,
                        effects: plan.effects,
                        requestBytes: UInt64(prepared.prepared.request.sanitizedArguments.data.count),
                        responseBytesLimit: plan.maximumResponseBytes,
                        payloadDigest: plan.payloadDigest,
                        executionConstraintDigest: plan.executionConstraintDigest,
                        artifactIDs: plan.artifactIDs,
                        workspaceID: plan.workspaceID,
                        descriptorID: plan.descriptorID,
                        schemaDigest: plan.schemaDigest,
                        trustRevision: plan.trustRevision,
                        idempotencyKey: plan.idempotencyKey,
                        credentialReference: plan.credentialReference,
                        resolvedSecretReferenceIDs: prepared.prepared.request
                            .sanitizedArguments.referencedSecretIDs
                    )
                    let body = try CanonicalJSON(.object(["value": .string("tool-result")]))
                    let resultText: String? = switch behavior {
                    case .complete(let value), .completeWithoutBoundary(let value),
                         .completeCrossingBoundary(let value),
                         .progressThenComplete(_, let value),
                         .blockedProgressThenComplete(_, _, let value),
                         .blockFirstAttemptBeforeBoundaryThenComplete(let value),
                         .blockFirstAttemptInsideBoundaryThenComplete(let value),
                         .throwOnceThenComplete(let value),
                         .throwAttemptsThenComplete(_, let value):
                        value
                    case .completeEmptyText, .failWithoutBoundary, .throwContractBeforeBoundary,
                         .throwCancellationBeforeBoundary,
                         .failAfterBoundary, .throwAcrossBoundary,
                         .throwAcrossBoundaryWithDiagnostic, .failAfterBoundaryThenBlockStream:
                        nil
                    }
                    let completesWithoutBoundary: Bool = switch behavior {
                    case .completeWithoutBoundary, .failWithoutBoundary,
                         .throwContractBeforeBoundary, .throwCancellationBeforeBoundary: true
                    case .completeEmptyText where isLocalPure: true
                    case .complete where isLocalPure: true
                    case .progressThenComplete where isLocalPure: true
                    case .blockedProgressThenComplete where isLocalPure: true
                    case .blockFirstAttemptBeforeBoundaryThenComplete where isLocalPure: true
                    case .throwOnceThenComplete where isLocalPure: true
                    case .throwAttemptsThenComplete where isLocalPure: true
                    default: false
                    }
                    if completesWithoutBoundary {
                        if case .throwOnceThenComplete = behavior, executionNumber == 1 {
                            throw ExecutorTestToolFailure.transportLost
                        }
                        if case .throwAttemptsThenComplete(let attempts, _) = behavior,
                           executionNumber <= attempts
                        {
                            throw ExecutorTestToolFailure.transportLost
                        }
                        if case .throwContractBeforeBoundary(let error) = behavior {
                            throw error
                        }
                        if case .throwCancellationBeforeBoundary = behavior {
                            throw CancellationError()
                        }
                        if case .progressThenComplete(let progress, _) = behavior {
                            continuation.yield(.progress(progress))
                        }
                        if case .blockedProgressThenComplete(let gate, let progress, _) = behavior {
                            await gate.suspendUntilReleased()
                            try Task.checkCancellation()
                            continuation.yield(.progress(progress))
                        }
                        if case .blockFirstAttemptBeforeBoundaryThenComplete = behavior,
                           executionNumber == 1
                        {
                            try await waitForExecutorToolCancellation(context.cancellation)
                        }
                        if case .failWithoutBoundary(let failure) = behavior {
                            continuation.yield(.failed(failure))
                            continuation.finish()
                            return
                        }
                        if case .completeEmptyText = behavior {
                            continuation.yield(.completed(try ToolResultCollection([
                                .text(try ToolTextResult("")),
                            ])))
                        } else {
                            guard let resultText else { throw ExecutorTestToolFailure.transportLost }
                            continuation.yield(.completed(try ToolResultCollection([
                                .text(try ToolTextResult(resultText)),
                            ])))
                        }
                        continuation.finish()
                        return
                    }
                    if case .blockFirstAttemptBeforeBoundaryThenComplete = behavior,
                       executionNumber == 1
                    {
                        try await waitForExecutorToolCancellation(context.cancellation)
                    }
                    _ = try await context.performBoundary(observation: observation) { control in
                        _ = await counter.crossedBoundary()
                        if case .blockFirstAttemptInsideBoundaryThenComplete = behavior,
                           executionNumber == 1
                        {
                            try await waitForExecutorToolCancellation(context.cancellation)
                        }
                        try await control.consumeResponseBytes(UInt64(body.data.count))
                        if case .throwAcrossBoundary = behavior {
                            throw ExecutorTestToolFailure.transportLost
                        }
                        if case .throwAcrossBoundaryWithDiagnostic(let diagnostic) = behavior {
                            throw ExecutorTestDiagnosticToolFailure(diagnostic: diagnostic)
                        }
                        if case .throwOnceThenComplete = behavior, executionNumber == 1 {
                            throw ExecutorTestToolFailure.transportLost
                        }
                        return ExternalOperationBoundaryCompletion(
                            value: .canonicalJSON(body),
                            responseDigest: body.fingerprint
                        )
                    }
                    if case .failAfterBoundary(let failure) = behavior {
                        continuation.yield(.failed(failure))
                    } else if case .failAfterBoundaryThenBlockStream(let gate, let failure) = behavior {
                        continuation.yield(.failed(failure))
                        await gate.suspendUntilReleased()
                    } else {
                        guard let resultText else { throw ExecutorTestToolFailure.transportLost }
                        continuation.yield(.completed(try ToolResultCollection([
                            .text(try ToolTextResult(resultText)),
                        ])))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum ExecutorTestToolFailure: Error {
    case transportLost
    case cancellationWasNotObserved
}

private func waitForExecutorToolCancellation(
    _ cancellation: any ToolCancellationChecking
) async throws -> Never {
    for _ in 0 ..< 5_000 {
        if await cancellation.isCancelled() { throw CancellationError() }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ExecutorTestToolFailure.cancellationWasNotObserved
}

struct ExecutorTestDiagnosticToolFailure: Error, CustomStringConvertible, Sendable {
    let diagnostic: String
    var description: String { diagnostic }
}

actor RecordingExecutorClock: AgentExecutionClock {
    private let timestamp: AgentTimestamp
    private var delays: [UInt64] = []

    init(_ rawValue: Int64 = 50_000) {
        timestamp = AgentTimestamp(rawValue: rawValue)
    }

    func now() async throws -> AgentTimestamp { timestamp }

    func sleep(milliseconds: UInt64) async throws {
        try Task.checkCancellation()
        delays.append(milliseconds)
        await Task.yield()
    }

    func recordedDelays() -> [UInt64] { delays }
}

struct RejectExternalAtExecutionPolicyEngine: ApprovalPolicyEngine, Sendable {
    let underlying: DefaultApprovalPolicyEngine

    var policyVersion: UInt32 { underlying.policyVersion }

    func evaluate(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?,
        feature: ApprovalFeatureState,
        interaction: ApprovalInteractionContext,
        candidateReceipts: [ApprovalReceipt],
        at timestamp: AgentTimestamp
    ) -> ApprovalPolicyEvaluation {
        underlying.evaluate(
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority,
            feature: feature,
            interaction: interaction,
            candidateReceipts: candidateReceipts,
            at: timestamp
        )
    }

    func bind(
        prepared: PreparedExternalOperationRequest,
        receipt: ApprovalReceipt,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        try await underlying.bind(
            prepared: prepared,
            receipt: receipt,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }

    func bindLocalPolicy(
        prepared: PreparedExternalOperationRequest,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        try await underlying.bindLocalPolicy(
            prepared: prepared,
            approvalID: approvalID,
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
        guard prepared.plan.kind == .localPure else {
            throw AgentContractError.authorizationDenied
        }
        try await underlying.validateCurrentAuthorization(
            receipt: receipt,
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }
}

struct SingleExecutorTestToolCatalog: ExecutableToolCatalog, Sendable {
    let toolValue: any ToolV2
    let snapshot: ToolCatalogSnapshot

    init(tool: any ToolV2) throws {
        toolValue = tool
        snapshot = try ToolCatalogSnapshot(revision: 1, descriptors: [tool.descriptor])
    }

    func localSnapshot() async throws -> ToolCatalogSnapshot { snapshot }

    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        descriptorID == toolValue.descriptor.id ? toolValue : nil
    }
}

struct ExecutorTestToolCatalog: ExecutableToolCatalog, Sendable {
    let toolValues: [any ToolV2]
    let snapshot: ToolCatalogSnapshot

    init(tools: [any ToolV2]) throws {
        precondition(!tools.isEmpty)
        toolValues = tools
        snapshot = try ToolCatalogSnapshot(revision: 1, descriptors: tools.map(\.descriptor))
    }

    func localSnapshot() async throws -> ToolCatalogSnapshot { snapshot }

    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        toolValues.first { $0.descriptor.id == descriptorID }
    }
}

func collectTerminalEvents(
    from handle: any AgentExecutionHandle,
    after cursor: AgentEventCursor? = nil,
    timeoutNanoseconds: UInt64 = 5_000_000_000
) async throws -> [AgentEventEnvelope] {
    // Wait through the durable status surface first. Racing an event iterator against a sleeping
    // child task can strand the structured task group when the producer is deliberately blocked;
    // polling gives every negative-path test a hard, deterministic completion oracle without
    // leaving an unstructured stream-consumer task behind.
    let pollInterval: UInt64 = 1_000_000
    let quotient = timeoutNanoseconds / pollInterval
    let roundedPolls = quotient + (timeoutNanoseconds % pollInterval == 0 ? 0 : 1)
    let maximumPolls = max(1, Int(clamping: roundedPolls))
    var reachedTerminal = false
    for _ in 0 ..< maximumPolls {
        let status = try await handle.status()
        if status.state.isTerminal {
            reachedTerminal = true
            break
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    guard reachedTerminal else { throw ExecutorIntegrationTestError.timeout }

    var events: [AgentEventEnvelope] = []
    for try await event in handle.events(after: cursor) {
        events.append(event)
        if event.payload.event.isRunTerminal { return events }
    }
    throw ExecutorIntegrationTestError.streamEndedUnexpectedly
}

func waitForStatus(
    _ expected: AgentRunState,
    handle: any AgentExecutionHandle,
    maximumPolls: Int = 1_000
) async throws -> AgentRunStatus {
    for _ in 0 ..< maximumPolls {
        let status = try await handle.status()
        if status.state == expected { return status }
        if status.state.isTerminal && status.state != expected {
            throw ExecutorIntegrationTestError.unexpectedTerminal(status.state)
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ExecutorIntegrationTestError.timeout
}

func waitForWorkerToStop(
    _ runID: AgentRunID,
    controller: AgentRunController,
    maximumPolls: Int = 1_000
) async throws {
    for _ in 0 ..< maximumPolls {
        if await controller.workers[runID] == nil { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ExecutorIntegrationTestError.timeout
}

func waitForExecutorCondition(
    maximumPolls: Int = 1_000,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0 ..< maximumPolls {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ExecutorIntegrationTestError.timeout
}

enum ExecutorIntegrationTestError: Error {
    case timeout
    case streamEndedUnexpectedly
    case unexpectedTerminal(AgentRunState)
}
