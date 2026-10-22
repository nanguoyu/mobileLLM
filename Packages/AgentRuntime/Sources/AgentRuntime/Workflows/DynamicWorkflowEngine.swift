// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

public struct WorkflowLaunchPreview: Hashable, Sendable {
    public let runID: WorkflowRunID
    public let metadata: WorkflowScriptMetadataV1
    public let source: String
    public let runtimeCapabilities: WorkflowRuntimeCapabilitiesV1
    public let limits: WorkflowRunLimitsV1
    public let requiresApproval: Bool
    public let reusedApprovalID: ApprovalID?
}

public enum DynamicWorkflowEngineError: Error, Hashable, Sendable {
    case runAlreadyExists
    case runNotFound
    case scriptReferenceMismatch
    case scriptMetadataMismatch
    case scriptOwnerMismatch
    case savedWorkflowPinMismatch
    case launchApprovalRequired
    case illegalRunState(WorkflowRunStateV1)
    case agentCallLimitExceeded
    case invocationOrderMismatch
    case nestedWorkflowUnavailable
    case outputUnavailable
    case anotherRootRunActive
}

private struct WorkflowPausedAtStableBoundary: Error, Sendable {}

/// Trusted application policy maps one script request into the existing subagent contract. This is
/// where model aliases, strict authority/budget attenuation, and future sandbox requirements are
/// resolved; orchestration JavaScript cannot construct authority directly.
public protocol WorkflowChildRequestBuilding: Sendable {
    func makeRequest(
        launch: WorkflowLaunchSnapshotV1,
        call: WorkflowAgentCallV1,
        prompt: String
    ) throws -> SubagentSpawnRequest

    /// Called inside atomic admission. Implementations may shrink their usual child share to
    /// fit remaining capacity, and must freeze/cache that exact request before returning it.
    func makeRequest(
        launch: WorkflowLaunchSnapshotV1,
        call: WorkflowAgentCallV1,
        prompt: String,
        budgetLimit: AgentBudget
    ) throws -> SubagentSpawnRequest
}

public extension WorkflowChildRequestBuilding {
    func makeRequest(
        launch: WorkflowLaunchSnapshotV1,
        call: WorkflowAgentCallV1,
        prompt: String,
        budgetLimit: AgentBudget
    ) throws -> SubagentSpawnRequest {
        // Existing host policies retain their exact request. The ledger still rejects any
        // reservation that does not fit; it never silently changes an already frozen request.
        try makeRequest(launch: launch, call: call, prompt: prompt)
    }
}

public struct ClosureWorkflowChildRequestBuilder: WorkflowChildRequestBuilding, Sendable {
    private let implementation: @Sendable (
        WorkflowLaunchSnapshotV1, WorkflowAgentCallV1, String
    ) throws -> SubagentSpawnRequest

    public init(
        _ implementation: @escaping @Sendable (
            WorkflowLaunchSnapshotV1, WorkflowAgentCallV1, String
        ) throws -> SubagentSpawnRequest
    ) {
        self.implementation = implementation
    }

    public func makeRequest(
        launch: WorkflowLaunchSnapshotV1,
        call: WorkflowAgentCallV1,
        prompt: String
    ) throws -> SubagentSpawnRequest {
        try implementation(launch, call, prompt)
    }
}

/// Allows the public runtime to use inline values today while a private app can inject encrypted,
/// content-addressed artifact storage without changing workflow semantics.
public protocol WorkflowValueStoring: Sendable {
    func store(_ value: CanonicalJSON, runID: WorkflowRunID) async throws -> WorkflowValueReferenceV1
    func load(_ reference: WorkflowValueReferenceV1) async throws -> CanonicalJSON
}

public struct InlineWorkflowValueStore: WorkflowValueStoring, Sendable {
    public init() {}
    public func store(_ value: CanonicalJSON, runID _: WorkflowRunID) async throws -> WorkflowValueReferenceV1 {
        .inline(value)
    }
    public func load(_ reference: WorkflowValueReferenceV1) async throws -> CanonicalJSON {
        switch reference {
        case .inline(let value): return value
        case .artifact: throw DynamicWorkflowEngineError.outputUnavailable
        }
    }
}

/// Durable, reconnectable Claude-style workflow coordinator. Preparing a launch never executes a
/// model. Execution begins only after an explicit launch approval has been journaled.
public actor DynamicWorkflowEngine {
    private struct ActiveRun {
        let token: UUID
        let session: DynamicWorkflowSession
        let task: Task<CanonicalJSON, Error>
    }

    private let journal: any DynamicWorkflowJournal
    private let runtime: any WorkflowScriptRuntimeProvider
    private let analyzer: DynamicWorkflowScriptAnalyzer
    private let spawner: any SubagentSpawning
    private let requestBuilder: any WorkflowChildRequestBuilding
    private let valueStore: any WorkflowValueStoring
    private let clock: any AgentExecutionClock
    private var active: [WorkflowRunID: ActiveRun] = [:]
    private var dataEraseSuspended = false

    public init(
        journal: any DynamicWorkflowJournal,
        runtime: any WorkflowScriptRuntimeProvider,
        spawner: any SubagentSpawning,
        requestBuilder: any WorkflowChildRequestBuilding,
        valueStore: any WorkflowValueStoring = InlineWorkflowValueStore(),
        clock: any AgentExecutionClock = SystemAgentExecutionClock(),
        analyzer: DynamicWorkflowScriptAnalyzer = .init()
    ) {
        self.journal = journal
        self.runtime = runtime
        self.spawner = spawner
        self.requestBuilder = requestBuilder
        self.valueStore = valueStore
        self.clock = clock
        self.analyzer = analyzer
    }

    public func prepareLaunch(
        script saved: SavedWorkflowScriptV1,
        snapshot: WorkflowLaunchSnapshotV1
    ) async throws -> WorkflowLaunchPreview {
        guard saved.script.reference == snapshot.scriptReference else {
            throw DynamicWorkflowEngineError.scriptReferenceMismatch
        }
        guard try await journal.loadProjection(for: snapshot.runID) == nil else {
            throw DynamicWorkflowEngineError.runAlreadyExists
        }
        let analyzed = try analyzer.analyze(saved.script)
        guard analyzed.metadata == saved.metadata else {
            throw DynamicWorkflowEngineError.scriptMetadataMismatch
        }
        guard snapshot.savedWorkflowOwners.contains(saved.owner) else {
            throw DynamicWorkflowEngineError.scriptOwnerMismatch
        }
        guard runtime.capabilities.satisfies(snapshot.runtimeRequirement) else {
            throw WorkflowScriptRuntimeError.unsupportedRequirement
        }
        try await journal.saveScript(saved)
        var dependencyPins: [String: WorkflowScriptReferenceV1] = [:]
        for name in analyzed.savedWorkflowNames {
            guard let dependency = try await journal.resolveScript(
                named: name,
                owners: snapshot.savedWorkflowOwners
            ) else { throw WorkflowJournalError.scriptNotFound }
            let dependencyAnalysis = try analyzer.analyze(dependency.script)
            guard dependencyAnalysis.metadata == dependency.metadata,
                  dependency.metadata.name == name
            else { throw DynamicWorkflowEngineError.scriptMetadataMismatch }
            dependencyPins[name] = dependency.script.reference
        }
        guard snapshot.savedWorkflowPins.isEmpty || snapshot.savedWorkflowPins == dependencyPins else {
            throw DynamicWorkflowEngineError.savedWorkflowPinMismatch
        }
        let preparedSnapshot = snapshot.pinningSavedWorkflows(dependencyPins)
        let timestamp = try await clock.now()
        let created = try WorkflowRunEventV1(
            eventID: WorkflowEventID(),
            runID: snapshot.runID,
            sequence: 1,
            timestamp: timestamp,
            previousDigest: nil,
            kind: .created(preparedSnapshot)
        )
        var projection = try await journal.append(try WorkflowEventAppendRequestV1(
            runID: snapshot.runID,
            expectedSequence: 0,
            expectedDigest: nil,
            events: [created]
        )).projection
        if !dependencyPins.isEmpty {
            projection = try await append(
                dependencyPins.keys.sorted().map { name in
                    .savedWorkflowPinned(name: name, reference: dependencyPins[name]!)
                },
                to: projection
            )
        }
        let reusable = try await journal.reusableLaunchApproval(for: preparedSnapshot)
        if let reusable {
            projection = try await append([
                .launchApproved(reusable.approvalID),
                .stateChanged(
                    from: .waitingForLaunchApproval,
                    to: .queued,
                    reason: "reusable-launch-approval"
                ),
            ], to: projection)
        }
        _ = projection
        return WorkflowLaunchPreview(
            runID: snapshot.runID,
            metadata: analyzed.metadata,
            source: saved.script.source,
            runtimeCapabilities: runtime.capabilities,
            limits: snapshot.limits,
            requiresApproval: reusable == nil,
            reusedApprovalID: reusable?.approvalID
        )
    }

    public func approveLaunch(
        runID: WorkflowRunID,
        approvalID: ApprovalID,
        reuseScope: WorkflowLaunchApprovalReuseScopeV1? = nil
    ) async throws {
        let projection = try await requiredProjection(runID)
        guard projection.state == .waitingForLaunchApproval else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        _ = try await append(
            [.launchApproved(approvalID),
             .stateChanged(from: .waitingForLaunchApproval, to: .queued, reason: "launch-approved")],
            to: projection
        )
        if let reuseScope {
            try await journal.saveLaunchApproval(try WorkflowLaunchApprovalV1(
                approvalID: approvalID,
                launch: projection.launch,
                reuseScope: reuseScope,
                createdAt: try await clock.now()
            ))
        }
    }

    public func denyLaunch(runID: WorkflowRunID, reason: String = "launch-denied") async throws {
        let projection = try await requiredProjection(runID)
        guard projection.state == .waitingForLaunchApproval else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        _ = try await append(
            [.stateChanged(from: .waitingForLaunchApproval, to: .cancelled, reason: reason)],
            to: projection
        )
    }

    /// Starts durable background execution and returns immediately. Repeated calls attach to the
    /// same in-process task; relaunch recovery reconstructs a new task from journal facts.
    public func start(runID: WorkflowRunID) async throws {
        guard !dataEraseSuspended else { throw WorkflowScriptRuntimeError.cancelled }
        let projection = try await requiredProjection(runID)
        guard projection.reconciliationCallID == nil,
              projection.state != .waitingForReconciliation
        else { throw DynamicWorkflowEngineError.illegalRunState(projection.state) }
        if active[runID] != nil { return }
        guard active.isEmpty else { throw DynamicWorkflowEngineError.anotherRootRunActive }
        let session = try await makeSession(runID: runID)
        let token = UUID()
        let task = Task { try await session.execute() }
        active[runID] = ActiveRun(token: token, session: session, task: task)
        Task { [weak self] in
            _ = await task.result
            await self?.removeActive(runID, token: token)
        }
    }

    /// Test/CLI convenience that still uses the same durable session and journal boundaries.
    public func runAndWait(runID: WorkflowRunID) async throws -> CanonicalJSON {
        if let existing = active[runID] { return try await existing.task.value }
        guard active.isEmpty else { throw DynamicWorkflowEngineError.anotherRootRunActive }
        let session = try await makeSession(runID: runID)
        let token = UUID()
        let task = Task { try await session.execute() }
        active[runID] = ActiveRun(token: token, session: session, task: task)
        defer {
            if active[runID]?.token == token { active[runID] = nil }
        }
        return try await task.value
    }

    public func pause(runID: WorkflowRunID) async throws {
        guard let current = active[runID] else {
            let projection = try await requiredProjection(runID)
            guard projection.state == .running || projection.state == .queued else {
                throw DynamicWorkflowEngineError.illegalRunState(projection.state)
            }
            _ = try await append([
                .stateChanged(from: projection.state, to: .paused, reason: "user-pause-offline")
            ], to: projection)
            return
        }
        try await current.session.requestPause()
        current.task.cancel()
        _ = await current.task.result
        active[runID] = nil
    }

    public func resume(runID: WorkflowRunID) async throws {
        if let current = active[runID] {
            let state = try await requiredProjection(runID).state
            if state == .pausing || state == .paused {
                try await current.session.resume()
                return
            }
            _ = await current.task.result
            active[runID] = nil
        }
        try await start(runID: runID)
    }

    /// Resolves an uncertain child operation through that child's durable AgentExecutor command,
    /// then queues the workflow for an explicit continuation. No child is retried here.
    public func reconcileAgent(
        runID: WorkflowRunID,
        callID: WorkflowAgentCallID,
        decision: AgentReconciliationDecision
    ) async throws {
        guard active[runID] == nil else {
            throw DynamicWorkflowEngineError.illegalRunState(.running)
        }
        var projection = try await requiredProjection(runID)
        guard projection.state == .waitingForReconciliation,
              projection.reconciliationCallID == callID,
              projection.outcomes[callID] == nil,
              let call = projection.calls.first(where: { $0.callID == callID }),
              let handleID = projection.submittedHandles[callID],
              projection.reconciliationDecision == nil
                || projection.reconciliationDecision == decision
        else { throw DynamicWorkflowEngineError.illegalRunState(projection.state) }
        if projection.reconciliationDecision == nil {
            projection = try await append([
                .reconciliationRequested(callID: callID, decision: decision),
            ], to: projection)
        }
        try await spawner.reconcile(
            handleID,
            runID: call.childRunID,
            decision: decision,
            generation: projection.reconciliationGeneration
        )
        _ = try await append([
            .reconciliationDecided(callID: callID, decision: decision),
            .stateChanged(
                from: .waitingForReconciliation,
                to: .queued,
                reason: "child-reconciliation-decided"
            ),
        ], to: projection)
    }

    /// Invalidates one logical call and the replay suffix, then starts a new durable attempt. A
    /// running workflow is first quiesced at a stable boundary.
    public func restartAgent(runID: WorkflowRunID, callID: WorkflowAgentCallID) async throws {
        if active[runID] != nil { try await pause(runID: runID) }
        var projection = try await requiredProjection(runID)
        guard projection.calls.contains(where: { $0.callID == callID }) else {
            throw WorkflowProjectionError.unknownAgentCall
        }
        guard projection.state == .paused || projection.state == .waitingForReconciliation else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        projection = try await append([
            .agentRestartRequested(callID: callID),
            .stateChanged(from: projection.state, to: .queued, reason: "agent-restart"),
        ], to: projection)
        _ = projection
        try await start(runID: runID)
    }

    public func stop(runID: WorkflowRunID) async throws {
        guard let current = active[runID] else {
            let projection = try await requiredProjection(runID)
            guard !projection.isTerminal else { return }
            if projection.launchApprovalID != nil,
               [.queued, .running, .pausing, .paused, .waitingForForeground,
                .waitingForReconciliation].contains(projection.state)
            {
                let session = try await makeSession(
                    runID: runID,
                    allowWaitingForReconciliation: true
                )
                try await session.stopAndDrain()
            } else {
                _ = try await append(
                    [.stateChanged(from: projection.state, to: .cancelled, reason: "user-stop")],
                    to: projection
                )
            }
            return
        }
        try await current.session.stop()
        current.task.cancel()
        _ = await current.task.result
    }

    public func suspendForDataErase() async throws {
        dataEraseSuspended = true
        for id in Array(active.keys) { try await stop(runID: id) }
    }

    public func resumeAfterDataErase() { dataEraseSuspended = false }

    public func quiesceForBackground(excluding runs: Set<WorkflowRunID> = []) async throws {
        for id in Array(active.keys) where !runs.contains(id) { try await deferToForeground(runID: id) }
    }

    public func projection(runID: WorkflowRunID) async throws -> WorkflowRunProjectionV1? {
        try await journal.loadProjection(for: runID)
    }

    /// Validates and stores an immutable candidate without launching it. This is the model-facing
    /// generation boundary: generated source remains inert until a separate prepared run is approved.
    @discardableResult
    public func registerScript(_ saved: SavedWorkflowScriptV1) async throws -> WorkflowScriptMetadataV1 {
        let analyzed = try analyzer.analyze(saved.script)
        guard analyzed.metadata == saved.metadata else {
            throw DynamicWorkflowEngineError.scriptMetadataMismatch
        }
        try await journal.saveScript(saved)
        return analyzed.metadata
    }

    public func savedScripts(
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> [SavedWorkflowScriptV1] {
        try await journal.listScripts(owners: owners)
    }

    public func events(
        runID: WorkflowRunID,
        after sequence: UInt64 = 0,
        limit: Int = 256
    ) async throws -> WorkflowJournalEventPage {
        try await journal.readEvents(runID: runID, after: sequence, limit: limit)
    }

    /// Marks a quiesced run as requiring foreground execution. It never starts or resumes work.
    public func deferToForeground(runID: WorkflowRunID) async throws {
        if active[runID] != nil { try await pause(runID: runID) }
        let projection = try await requiredProjection(runID)
        guard !projection.isTerminal else { return }
        guard [.queued, .running, .paused].contains(projection.state) else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        _ = try await append([
            .stateChanged(from: projection.state, to: .waitingForForeground, reason: "foreground-required")
        ], to: projection)
    }

    private func makeSession(
        runID: WorkflowRunID,
        allowWaitingForReconciliation: Bool = false
    ) async throws -> DynamicWorkflowSession {
        let projection = try await requiredProjection(runID)
        guard projection.launchApprovalID != nil else {
            throw DynamicWorkflowEngineError.launchApprovalRequired
        }
        let executableStates: Set<WorkflowRunStateV1> = [
            .queued, .running, .pausing, .paused, .waitingForForeground,
        ]
        guard executableStates.contains(projection.state)
                || (allowWaitingForReconciliation
                    && projection.state == .waitingForReconciliation)
        else { throw DynamicWorkflowEngineError.illegalRunState(projection.state) }
        guard let saved = try await journal.loadScript(
            projection.launch.scriptReference,
            owners: projection.launch.savedWorkflowOwners
        ) else {
            throw WorkflowJournalError.scriptNotFound
        }
        let analyzed = try analyzer.analyze(saved.script)
        guard analyzed.metadata == saved.metadata else {
            throw DynamicWorkflowEngineError.scriptMetadataMismatch
        }
        return try DynamicWorkflowSession(
            projection: projection,
            script: analyzed,
            journal: journal,
            runtime: runtime,
            spawner: spawner,
            requestBuilder: requestBuilder,
            valueStore: valueStore,
            clock: clock,
            analyzer: analyzer
        )
    }

    private func requiredProjection(_ runID: WorkflowRunID) async throws -> WorkflowRunProjectionV1 {
        guard let projection = try await journal.loadProjection(for: runID) else {
            throw DynamicWorkflowEngineError.runNotFound
        }
        return projection
    }

    private func append(
        _ kinds: [WorkflowRunEventKindV1],
        to projection: WorkflowRunProjectionV1
    ) async throws -> WorkflowRunProjectionV1 {
        let timestamp = try await clock.now()
        var sequence = projection.lastSequence
        var digest: StableDigest? = projection.lastDigest
        var events: [WorkflowRunEventV1] = []
        for kind in kinds {
            sequence += 1
            let event = try WorkflowRunEventV1(
                eventID: WorkflowEventID(), runID: projection.runID, sequence: sequence,
                timestamp: timestamp, previousDigest: digest, kind: kind
            )
            digest = event.recordDigest
            events.append(event)
        }
        return try await journal.append(try WorkflowEventAppendRequestV1(
            runID: projection.runID,
            expectedSequence: projection.lastSequence,
            expectedDigest: projection.lastDigest,
            events: events
        )).projection
    }

    private func removeActive(_ runID: WorkflowRunID, token: UUID) {
        guard active[runID]?.token == token else { return }
        active[runID] = nil
    }
}

private actor DynamicWorkflowSession {
    private let script: AnalyzedWorkflowScriptV1
    private let journal: any DynamicWorkflowJournal
    private let runtime: any WorkflowScriptRuntimeProvider
    private let spawner: any SubagentSpawning
    private let requestBuilder: any WorkflowChildRequestBuilding
    private let valueStore: any WorkflowValueStoring
    private let clock: any AgentExecutionClock
    private let analyzer: DynamicWorkflowScriptAnalyzer
    private let scheduler: WorkflowDispatchScheduler
    private let replay: WorkflowReplayCursor
    private let childRequestValidator = WorkflowChildRequestValidator()
    private let workflowBudget: WorkflowBudgetCoordinator
    private let order = WorkflowInvocationOrderGate()
    private let invocationCounter = WorkflowInvocationCounter()
    private let appendMutex = WorkflowAppendMutex()
    private let signals: WorkflowHostSignalBuffer
    private let budgetCounter: WorkflowBudgetCounter
    private var projection: WorkflowRunProjectionV1
    private var stopped = false
    private var evidenceCache: (sequence: UInt64, value: JSONValue)?

    init(
        projection: WorkflowRunProjectionV1,
        script: AnalyzedWorkflowScriptV1,
        journal: any DynamicWorkflowJournal,
        runtime: any WorkflowScriptRuntimeProvider,
        spawner: any SubagentSpawning,
        requestBuilder: any WorkflowChildRequestBuilding,
        valueStore: any WorkflowValueStoring,
        clock: any AgentExecutionClock,
        analyzer: DynamicWorkflowScriptAnalyzer
    ) throws {
        self.projection = projection
        self.script = script
        self.journal = journal
        self.runtime = runtime
        self.spawner = spawner
        self.requestBuilder = requestBuilder
        self.valueStore = valueStore
        self.clock = clock
        self.analyzer = analyzer
        scheduler = WorkflowDispatchScheduler(
            maximumConcurrentAgents: Int(projection.launch.limits.maximumConcurrentAgents)
        )
        replay = try WorkflowReplayCursor(launch: projection.launch, priorProjection: projection)
        workflowBudget = try WorkflowBudgetCoordinator(projection: projection)
        signals = WorkflowHostSignalBuffer(limits: projection.launch.limits)
        budgetCounter = WorkflowBudgetCounter(
            total: projection.launch.budget.limits[.outputTokens],
            spent: projection.usage.quantities[.outputTokens]
        )
    }

    func execute() async throws -> CanonicalJSON {
        do {
            if projection.state != .running {
                projection = try await append([.stateChanged(
                    from: projection.state, to: .running, reason: "execution-started"
                )])
            }
            let host = makeHost(depth: 0)
            let result = try await runtime.execute(
                script,
                args: projection.launch.args,
                limits: projection.launch.limits,
                requirement: projection.launch.runtimeRequirement,
                host: host
            )
            try await flushSignals()
            if stopped {
                try await terminateAsCancelled()
                throw WorkflowScriptRuntimeError.cancelled
            }
            let reference = try await valueStore.store(result, runID: projection.runID)
            projection = try await append([
                .outputCommitted(reference),
                .stateChanged(from: projection.state, to: .completed, reason: nil),
            ])
            return result
        } catch let runtimeError as WorkflowScriptRuntimeError where runtimeError == .cancelled {
            if projection.state == .pausing {
                projection = try await append([
                    .stateChanged(from: .pausing, to: .paused, reason: "pause-checkpoint")
                ])
                throw WorkflowPausedAtStableBoundary()
            }
            if projection.state != .waitingForReconciliation {
                try await terminateAsCancelled()
            }
            throw runtimeError
        } catch is CancellationError {
            if projection.state == .pausing {
                projection = try await append([
                    .stateChanged(from: .pausing, to: .paused, reason: "pause-checkpoint")
                ])
                throw WorkflowPausedAtStableBoundary()
            }
            if projection.state != .waitingForReconciliation {
                try await terminateAsCancelled()
            }
            throw WorkflowScriptRuntimeError.cancelled
        } catch let childFailure as WorkflowChildExecutionFailed {
            if !projection.isTerminal {
                try? await flushSignals()
                projection = try await append([
                    .failureCommitted(childFailure.failure.safeMessage),
                    .stateChanged(from: projection.state, to: .failed, reason: childFailure.failure.code),
                ])
            }
            throw childFailure
        } catch {
            if projection.state == .waitingForReconciliation { throw error }
            if !projection.isTerminal {
                // JavaScriptCore transports host failures through a bounded bridge error. Recover
                // the already-journaled typed child failure so the workflow terminal record uses
                // only its explicitly safe message and stable code, never debug/error wrapping.
                let durableChildFailure = projection.calls.reversed().compactMap { call -> AgentFailure? in
                    guard case .failed(let failure, _) = projection.outcomes[call.callID] else {
                        return nil
                    }
                    return failure
                }.first
                let message = durableChildFailure?.safeMessage
                    ?? Self.sanitize(String(describing: error))
                try? await flushSignals()
                projection = try await append([
                    .failureCommitted(message),
                    .stateChanged(
                        from: projection.state,
                        to: .failed,
                        reason: durableChildFailure?.code ?? "workflow-failed"
                    ),
                ])
            }
            throw error
        }
    }

    private func makeHost(depth: UInt8) -> WorkflowScriptHost {
        let router = WorkflowInvocationRouter(
            counter: invocationCounter,
            maximumLocalSequence: projection.launch.limits.maximumAgentCalls
        )
        let savedCall: (@Sendable (String, CanonicalJSON?) async throws -> JSONValue)?
        if depth < projection.launch.limits.maximumNestedWorkflowDepth {
            savedCall = { [weak self] name, args in
                guard let self else { throw CancellationError() }
                return try await self.executeSavedWorkflow(named: name, args: args, depth: depth + 1)
            }
        } else {
            savedCall = nil
        }
        return WorkflowScriptHost(
            agent: { [weak self] invocation in
                guard let self else { throw CancellationError() }
                let global = try await router.map(invocation)
                return try await self.invokeAgent(global)
            },
            callSavedWorkflow: savedCall,
            phase: { [signals] in signals.recordPhase($0) },
            log: { [signals] in signals.recordLog($0) },
            budget: { [budgetCounter] in budgetCounter.snapshot() },
            webEvidence: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.recordedWebEvidence()
            }
        )
    }

    private func recordedWebEvidence() async throws -> JSONValue {
        let sequence = projection.lastSequence
        if let cached = evidenceCache, cached.sequence == sequence { return cached.value }
        var latest: [UInt32: WorkflowAgentCallV1] = [:]
        for call in projection.calls { latest[call.ordinal] = call }
        let calls = latest.values.sorted { $0.ordinal < $1.ordinal }
        var records: [(label: String, observation: WorkflowWebObservation)] = []
        for call in calls where projection.outcomes[call.callID] != nil {
            try Task.checkCancellation()
            guard let handle = projection.submittedHandles[call.callID] else { continue }
            for observation in try await spawner.webObservations(handle) {
                records.append((call.options.label ?? "agent-\(call.ordinal)", observation))
            }
            if records.count > WorkflowWebEvidence.maximumObservations { break }
        }
        let value = try WorkflowWebEvidence.packet(records)
        if projection.lastSequence == sequence { evidenceCache = (sequence, value) }
        return value
    }

    private func executeSavedWorkflow(
        named name: String,
        args: CanonicalJSON?,
        depth: UInt8
    ) async throws -> JSONValue {
        guard depth <= projection.launch.limits.maximumNestedWorkflowDepth else {
            throw DynamicWorkflowEngineError.nestedWorkflowUnavailable
        }
        guard let pinned = projection.launch.savedWorkflowPins[name],
              projection.savedWorkflowPins[name] == pinned,
              let saved = try await journal.loadScript(
                  pinned,
                  owners: projection.launch.savedWorkflowOwners
              )
        else { throw DynamicWorkflowEngineError.nestedWorkflowUnavailable }
        let analyzed = try analyzer.analyze(saved.script)
        guard analyzed.metadata == saved.metadata, analyzed.metadata.name == name else {
            throw DynamicWorkflowEngineError.scriptMetadataMismatch
        }
        guard runtime.capabilities.satisfies(projection.launch.runtimeRequirement) else {
            throw WorkflowScriptRuntimeError.unsupportedRequirement
        }
        let result = try await runtime.execute(
            analyzed,
            args: args,
            limits: projection.launch.limits,
            requirement: projection.launch.runtimeRequirement,
            host: makeHost(depth: depth)
        )
        return try JSONDecoder().decode(JSONValue.self, from: result.data)
    }

    func requestPause() async throws {
        guard projection.state == .running else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        await scheduler.pause()
        projection = try await append([.stateChanged(from: .running, to: .pausing, reason: "user-pause")])
        try await scheduler.waitUntilPaused()
    }

    func resume() async throws {
        guard projection.state == .pausing || projection.state == .paused else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        await scheduler.resume()
        projection = try await append([.stateChanged(from: projection.state, to: .running, reason: "user-resume")])
    }

    func stop() async throws {
        stopped = true
        await scheduler.stop()
        let unsettled = projection.calls.compactMap { call -> (WorkflowAgentCallV1, AgentExecutionHandleID)? in
            guard projection.outcomes[call.callID] == nil,
                  let handle = projection.submittedHandles[call.callID]
            else { return nil }
            return (call, handle)
        }
        for (call, handle) in unsettled {
            do {
                try await spawner.cancel(handle, runID: call.childRunID)
            } catch {
                if let terminal = try? await spawner.terminalResult(handle),
                   terminal.runID == call.childRunID, terminal.handleID == handle {
                    if case .failed(let failure, _) = terminal.outcome, failure.externalEffect == .uncertain {
                        try await suspendForReconciliation(callID: call.callID, reason: failure.safeMessage)
                        throw WorkflowScriptRuntimeError.hostFailure("child cancellation requires reconciliation")
                    }
                    // The active collection task (or stopAndDrain after recovery) still commits
                    // the exact terminal result and usage; no external operation is repeated.
                    continue
                }
                try await suspendForReconciliation(
                    callID: call.callID,
                    reason: "Unable to durably cancel a submitted child."
                )
                throw WorkflowScriptRuntimeError.hostFailure(
                    "child cancellation requires reconciliation"
                )
            }
        }
    }

    /// Relaunch recovery has no live script task whose cancellation handlers can drain children.
    /// Explicit stop therefore performs the same cancellation/collection settlement itself.
    func stopAndDrain() async throws {
        try await stop()
        let unsettled = projection.calls.filter {
            projection.outcomes[$0.callID] == nil && projection.submittedHandles[$0.callID] != nil
        }
        for call in unsettled {
            guard let handleID = projection.submittedHandles[call.callID] else { continue }
            let admission = try await workflowBudget.admit(
                request: nil,
                call: call,
                isRecoveredSubmission: true
            )
            try await settleAfterCancellation(
                call: call,
                handleID: handleID,
                admission: admission
            )
        }
        try await terminateAsCancelled()
    }

    private func invokeAgent(_ invocation: WorkflowAgentInvocation) async throws -> WorkflowAgentBridgeResult {
        guard !stopped else { return .stopped }
        guard invocation.sequence <= projection.launch.limits.maximumAgentCalls else {
            throw DynamicWorkflowEngineError.agentCallLimitExceeded
        }
        try await order.wait(for: invocation.sequence)
        do {
            try await flushSignals()
            let decision = try await replay.next(prompt: invocation.prompt, options: invocation.options)
            switch decision {
            case .reuse(_, let outcome):
                await order.complete(invocation.sequence)
                return try await bridge(outcome)
            case .continue(let call):
                await order.complete(invocation.sequence)
                return try await execute(call: call, prompt: invocation.prompt, prepared: true)
            case .execute(let call):
                try await invalidateUnsettledSuffix(startingAt: call.ordinal)
                projection = try await append([.agentCallPrepared(call)])
                await order.complete(invocation.sequence)
                return try await execute(call: call, prompt: invocation.prompt, prepared: false)
            }
        } catch {
            await order.fail(invocation.sequence)
            throw error
        }
    }

    /// A changed rolling prefix makes every later prior call unreachable. Submitted children must
    /// be durably cancelled before the replacement attempt starts; otherwise a paid or effectful
    /// child could escape while the recovered-budget fence waits forever.
    private func invalidateUnsettledSuffix(startingAt ordinal: UInt32) async throws {
        let stale = projection.calls.filter {
            $0.ordinal >= ordinal && projection.outcomes[$0.callID] == nil
        }
        guard !stale.isEmpty else { return }

        for call in stale {
            guard let handle = projection.submittedHandles[call.callID] else { continue }
            do {
                try await spawner.cancel(handle, runID: call.childRunID)
            } catch {
                projection = try await append([
                    .reconciliationRequired(
                        callID: call.callID,
                        reason: "Unable to cancel an invalidated recovered child"
                    ),
                    .stateChanged(
                        from: projection.state,
                        to: .waitingForReconciliation,
                        reason: "recovered-child-cancel-failed"
                    ),
                ])
                throw WorkflowScriptRuntimeError.hostFailure(
                    "invalidated child requires reconciliation"
                )
            }
        }

        projection = try await append(stale.map {
            .agentCallSettled(callID: $0.callID, outcome: .stopped(usage: .zero))
        })
        for call in stale where projection.submittedHandles[call.callID] != nil {
            _ = try await workflowBudget.abandonRecovered(callID: call.callID)
        }
    }

    private func execute(
        call: WorkflowAgentCallV1,
        prompt: String,
        prepared _: Bool
    ) async throws -> WorkflowAgentBridgeResult {
        try await scheduler.run { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.executeWithPermit(call: call, prompt: prompt)
        }
    }

    private func executeWithPermit(
        call: WorkflowAgentCallV1,
        prompt: String
    ) async throws -> WorkflowAgentBridgeResult {
        let handleID: AgentExecutionHandleID
        let admission: WorkflowBudgetAdmission
        if let existing = projection.submittedHandles[call.callID] {
            handleID = existing
            admission = try await workflowBudget.admit(
                request: nil,
                call: call,
                isRecoveredSubmission: true
            )
        } else {
            let launch = projection.launch
            let builder = requestBuilder
            let validator = childRequestValidator
            let admitted = try await workflowBudget.admitAvailable(call: call) { remaining in
                let request = try builder.makeRequest(
                    launch: launch, call: call, prompt: prompt, budgetLimit: remaining
                )
                try validator.validate(request, launch: launch, call: call)
                return request
            }
            let request = admitted.request
            admission = admitted.admission
            do {
                handleID = try await spawner.spawn(request)
            } catch {
                try? await workflowBudget.releaseUnsubmitted(admission)
                throw error
            }
            projection = try await append([.agentChildSubmitted(callID: call.callID, handleID: handleID)])
        }
        let result: SubagentResult
        do {
            result = try await spawner.collect(handleID, stallMilliseconds: call.options.stallMilliseconds)
        } catch let timeout as SubagentStallTimeout {
            try await settleAfterCancellation(call: call, handleID: handleID, admission: admission)
            throw WorkflowScriptRuntimeError.hostFailure("Child agent made no observable progress for \(timeout.milliseconds) ms and was stopped.")
        } catch SubagentSpawnError.reconciliationRequired(let failure) {
            projection = try await append([
                .reconciliationRequired(callID: call.callID, reason: failure.safeMessage),
                .stateChanged(
                    from: projection.state,
                    to: .waitingForReconciliation,
                    reason: failure.code
                ),
            ])
            throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
        } catch {
            if Task.isCancelled {
                try await settleAfterCancellation(
                    call: call,
                    handleID: handleID,
                    admission: admission
                )
            }
            throw error
        }
        guard result.runID == call.childRunID, result.handleID == handleID else {
            throw SubagentSpawnError.invalidResult
        }
        if case .failed(let failure, _) = result.outcome,
           failure.externalEffect == .uncertain
        {
            projection = try await append([
                .reconciliationRequired(callID: call.callID, reason: failure.safeMessage),
                .stateChanged(
                    from: projection.state,
                    to: .waitingForReconciliation,
                    reason: failure.code
                ),
            ])
            throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
        }
        switch result.outcome {
        case .failed(let failure, let usage)
            where failure.classification != .availabilityRelated:
            let nextUsage = try await commitSettlement(
                call: call,
                admission: admission,
                outcome: .failed(failure: failure, usage: usage),
                usage: usage
            )
            budgetCounter.update(spent: nextUsage.quantities[.outputTokens])
            throw WorkflowChildExecutionFailed(failure: failure)
        case .cancelled where stopped:
            let nextUsage = try await commitSettlement(
                call: call,
                admission: admission,
                outcome: .stopped(usage: result.usage),
                usage: result.usage
            )
            budgetCounter.update(spent: nextUsage.quantities[.outputTokens])
            return .stopped
        case .cancelled:
            let failure = try Self.childCancelledFailure()
            let nextUsage = try await commitSettlement(
                call: call,
                admission: admission,
                outcome: .failed(failure: failure, usage: .zero),
                usage: .zero
            )
            budgetCounter.update(spent: nextUsage.quantities[.outputTokens])
            throw WorkflowChildExecutionFailed(failure: failure)
        case .completed, .failed:
            break
        }
        let normalized = try await normalize(result)
        let nextUsage = try await commitSettlement(
            call: call,
            admission: admission,
            outcome: normalized.outcome,
            usage: normalized.usage
        )
        budgetCounter.update(spent: nextUsage.quantities[.outputTokens])
        return normalized.bridge
    }

    /// A cancelled host task is not allowed to abandon its durable child. Cleanup runs in an
    /// uncancelled task, waits for the child's terminal result, and journals exactly one settlement
    /// before script cancellation can advance the workflow to a terminal state.
    private func settleAfterCancellation(
        call: WorkflowAgentCallV1,
        handleID: AgentExecutionHandleID,
        admission: WorkflowBudgetAdmission
    ) async throws {
        if projection.outcomes[call.callID] != nil { return }
        let spawner = self.spawner
        let cleanup = Task.detached {
            do {
                try await spawner.cancel(handleID, runID: call.childRunID)
                return try await spawner.collect(handleID)
            } catch {
                // Cancellation acknowledgement/event-stream races do not invalidate a committed
                // terminal result. Unknown live outcomes still require reconciliation below.
                if let terminal = try await spawner.terminalResult(handleID) { return terminal }
                throw error
            }
        }
        let result: SubagentResult
        do {
            result = try await cleanup.value
        } catch SubagentSpawnError.reconciliationRequired(let failure) {
            try await suspendForReconciliation(callID: call.callID, reason: failure.safeMessage)
            throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
        } catch {
            try await suspendForReconciliation(
                callID: call.callID,
                reason: "Unable to prove the submitted child was cancelled."
            )
            throw WorkflowScriptRuntimeError.hostFailure(
                "child cancellation requires reconciliation"
            )
        }
        guard result.runID == call.childRunID, result.handleID == handleID else {
            try await suspendForReconciliation(
                callID: call.callID,
                reason: "The cancelled child returned an invalid durable identity."
            )
            throw SubagentSpawnError.invalidResult
        }
        if projection.outcomes[call.callID] != nil { return }
        switch result.outcome {
        case .cancelled:
            _ = try await commitSettlement(
                call: call,
                admission: admission,
                outcome: .stopped(usage: result.usage),
                usage: result.usage
            )
        case .completed, .failed:
            if case .failed(let failure, _) = result.outcome,
               failure.externalEffect == .uncertain
            {
                try await suspendForReconciliation(callID: call.callID, reason: failure.safeMessage)
                throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
            }
            if case .failed(let failure, let usage) = result.outcome,
               failure.classification != .availabilityRelated
            {
                _ = try await commitSettlement(
                    call: call,
                    admission: admission,
                    outcome: .failed(failure: failure, usage: usage),
                    usage: usage
                )
            } else {
                let normalized = try await normalize(result)
                _ = try await commitSettlement(
                    call: call,
                    admission: admission,
                    outcome: normalized.outcome,
                    usage: normalized.usage
                )
            }
        }
    }

    private func suspendForReconciliation(
        callID: WorkflowAgentCallID,
        reason: String
    ) async throws {
        guard !projection.isTerminal else { return }
        if projection.reconciliationCallID == nil {
            projection = try await append([
                .reconciliationRequired(callID: callID, reason: reason),
                .stateChanged(
                    from: projection.state,
                    to: .waitingForReconciliation,
                    reason: "child-lifecycle-uncertain"
                ),
            ])
        }
    }

    /// Couples budget settlement and its durable usage event under the same append critical section.
    /// Without this boundary, parallel children could commit cumulative snapshots out of order.
    private func commitSettlement(
        call: WorkflowAgentCallV1,
        admission: WorkflowBudgetAdmission,
        outcome: WorkflowAgentOutcomeV1,
        usage: AgentUsage
    ) async throws -> AgentUsage {
        try await appendMutex.run { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performSettlementAndInstall(
                call: call,
                admission: admission,
                outcome: outcome,
                usage: usage
            )
        }
    }

    private func performSettlementAndInstall(
        call: WorkflowAgentCallV1,
        admission: WorkflowBudgetAdmission,
        outcome: WorkflowAgentOutcomeV1,
        usage: AgentUsage
    ) async throws -> AgentUsage {
        let nextUsage = try await workflowBudget.settle(
            call: call,
            admission: admission,
            actualUsage: usage
        )
        projection = try await performAppend([
            .agentCallSettled(callID: call.callID, outcome: outcome),
            .usageCommitted(nextUsage),
        ])
        return nextUsage
    }

    private func normalize(_ result: SubagentResult) async throws -> (
        outcome: WorkflowAgentOutcomeV1, bridge: WorkflowAgentBridgeResult, usage: AgentUsage
    ) {
        switch result.outcome {
        case .completed(let answer, let usage):
            let value: JSONValue
            if let structured = answer.structuredOutput { value = structured }
            else if let text = answer.text { value = .string(text) }
            else { throw DynamicWorkflowEngineError.outputUnavailable }
            let canonical = try CanonicalJSON(value)
            guard canonical.data.count <= projection.launch.limits.maximumSerializedValueBytes else {
                throw WorkflowScriptRuntimeError.invalidResult("subagent value exceeds workflow limit")
            }
            let reference = try await valueStore.store(canonical, runID: projection.runID)
            return (.completed(value: reference, usage: usage), .value(value), usage)
        case .failed(let failure, let usage):
            guard failure.classification == .availabilityRelated else {
                throw WorkflowChildExecutionFailed(failure: failure)
            }
            return (
                .unavailable(reason: failure.safeMessage, usage: usage),
                .unavailable(failure.safeMessage),
                usage
            )
        case .cancelled:
            throw WorkflowChildExecutionFailed(failure: try Self.childCancelledFailure())
        }
    }

    private func bridge(_ outcome: WorkflowAgentOutcomeV1) async throws -> WorkflowAgentBridgeResult {
        switch outcome {
        case .completed(let reference, _):
            let canonical = try await valueStore.load(reference)
            return .value(try JSONDecoder().decode(JSONValue.self, from: canonical.data))
        case .unavailable(let reason, _): return .unavailable(reason)
        case .failed(let failure, _):
            throw WorkflowChildExecutionFailed(failure: failure)
        case .stopped: return .stopped
        }
    }

    private static func childCancelledFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "workflow.child-cancelled",
            classification: .cancelled,
            safeMessage: "A child agent was cancelled before producing a result.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(
                classification: .internalMetadata,
                policyVersion: 1
            )
        )
    }

    private func flushSignals() async throws {
        let drained = try signals.drain()
        guard !drained.isEmpty else { return }
        let kinds = drained.map { signal -> WorkflowRunEventKindV1 in
            switch signal {
            case .phase(let value): return .phaseStarted(value)
            case .log(let value): return .logAppended(value)
            }
        }
        projection = try await append(kinds)
    }

    private func append(_ kinds: [WorkflowRunEventKindV1]) async throws -> WorkflowRunProjectionV1 {
        try await appendMutex.run { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performAppendAndInstall(kinds)
        }
    }

    private func performAppendAndInstall(
        _ kinds: [WorkflowRunEventKindV1]
    ) async throws -> WorkflowRunProjectionV1 {
        let next = try await performAppend(kinds)
        projection = next
        return next
    }

    private func performAppend(_ kinds: [WorkflowRunEventKindV1]) async throws -> WorkflowRunProjectionV1 {
        let timestamp = try await clock.now()
        var sequence = projection.lastSequence
        var digest: StableDigest? = projection.lastDigest
        var events: [WorkflowRunEventV1] = []
        for kind in kinds {
            let (next, overflow) = sequence.addingReportingOverflow(1)
            guard !overflow else { throw WorkflowScriptRuntimeError.internalInvariant("event sequence overflow") }
            sequence = next
            let event = try WorkflowRunEventV1(
                eventID: WorkflowEventID(), runID: projection.runID, sequence: sequence,
                timestamp: timestamp, previousDigest: digest, kind: kind
            )
            digest = event.recordDigest
            events.append(event)
        }
        return try await journal.append(try WorkflowEventAppendRequestV1(
            runID: projection.runID,
            expectedSequence: projection.lastSequence,
            expectedDigest: projection.lastDigest,
            events: events
        )).projection
    }

    private func terminateAsCancelled() async throws {
        guard !projection.isTerminal else { return }
        projection = try await append([
            .stateChanged(from: projection.state, to: .cancelled, reason: "execution-cancelled")
        ])
    }

    private static func sanitize(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).prefix(2_048).description
    }
}

private struct WorkflowChildExecutionFailed: Error, Sendable, CustomStringConvertible {
    let failure: AgentFailure
    var description: String { failure.safeMessage }
}

private actor WorkflowAppendMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
        do {
            let value = try await operation()
            unlock()
            return value
        } catch {
            unlock()
            throw error
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor WorkflowInvocationOrderGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var expected: UInt32 = 1
    private var waiters: [UInt32: Waiter] = [:]
    private var failure: Error?

    func wait(for sequence: UInt32) async throws {
        if let failure { throw failure }
        guard sequence >= expected, waiters[sequence] == nil else {
            throw DynamicWorkflowEngineError.invocationOrderMismatch
        }
        if sequence == expected { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[sequence] = Waiter(id: id, continuation: continuation)
                if Task.isCancelled { cancel(sequence: sequence, id: id) }
            }
        } onCancel: {
            Task { await self.cancel(sequence: sequence, id: id) }
        }
    }

    func complete(_ sequence: UInt32) {
        guard sequence == expected else { return }
        expected += 1
        waiters.removeValue(forKey: expected)?.continuation.resume()
    }

    func fail(_ sequence: UInt32) {
        guard sequence == expected else { return }
        failure = DynamicWorkflowEngineError.invocationOrderMismatch
        let blocked = waiters.values.map(\.continuation)
        waiters.removeAll()
        for waiter in blocked { waiter.resume(throwing: failure!) }
    }

    private func cancel(sequence: UInt32, id: UUID) {
        guard waiters[sequence]?.id == id else { return }
        failure = CancellationError()
        let blocked = waiters.values.map(\.continuation)
        waiters.removeAll()
        for waiter in blocked { waiter.resume(throwing: failure!) }
    }
}

private actor WorkflowInvocationCounter {
    private var nextValue: UInt32 = 1

    func next() throws -> UInt32 {
        guard nextValue > 0 else {
            throw WorkflowScriptRuntimeError.internalInvariant("workflow invocation counter overflow")
        }
        let value = nextValue
        nextValue = nextValue == UInt32.max ? 0 : nextValue + 1
        return value
    }
}

/// Converts each JavaScript realm's local call sequence into one run-global started order. This is
/// required when a root script invokes a saved script whose provider-local sequence restarts at 1.
private actor WorkflowInvocationRouter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let counter: WorkflowInvocationCounter
    private let maximumLocalSequence: UInt32
    private var expectedLocal: UInt32 = 1
    private var waiters: [UInt32: Waiter] = [:]
    private var failure: Error?

    init(counter: WorkflowInvocationCounter, maximumLocalSequence: UInt32) {
        self.counter = counter
        self.maximumLocalSequence = maximumLocalSequence
    }

    func map(_ invocation: WorkflowAgentInvocation) async throws -> WorkflowAgentInvocation {
        if let failure { throw failure }
        guard invocation.sequence <= maximumLocalSequence else {
            throw DynamicWorkflowEngineError.agentCallLimitExceeded
        }
        guard invocation.sequence >= expectedLocal, waiters[invocation.sequence] == nil else {
            throw DynamicWorkflowEngineError.invocationOrderMismatch
        }
        if invocation.sequence != expectedLocal {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[invocation.sequence] = Waiter(id: id, continuation: continuation)
                    if Task.isCancelled { cancel(sequence: invocation.sequence, id: id) }
                }
            } onCancel: {
                Task { await self.cancel(sequence: invocation.sequence, id: id) }
            }
        }
        let global = try await counter.next()
        expectedLocal += 1
        waiters.removeValue(forKey: expectedLocal)?.continuation.resume()
        return WorkflowAgentInvocation(
            sequence: global,
            prompt: invocation.prompt,
            options: invocation.options
        )
    }

    private func cancel(sequence: UInt32, id: UUID) {
        guard waiters[sequence]?.id == id else { return }
        failure = CancellationError()
        let blocked = waiters.values.map(\.continuation)
        waiters.removeAll()
        for waiter in blocked { waiter.resume(throwing: failure!) }
    }
}

private final class WorkflowBudgetCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: UInt64
    private var spent: UInt64

    init(total: UInt64, spent: UInt64) { self.total = total; self.spent = spent }
    func snapshot() -> WorkflowBudgetSnapshot {
        lock.lock(); defer { lock.unlock() }
        return WorkflowBudgetSnapshot(totalOutputTokens: total, spentOutputTokens: spent)
    }
    func update(spent: UInt64) {
        lock.lock(); self.spent = max(self.spent, spent); lock.unlock()
    }
}

private final class WorkflowHostSignalBuffer: @unchecked Sendable {
    enum Signal { case phase(String), log(String) }
    private let lock = NSLock()
    private let limits: WorkflowRunLimitsV1
    private var signals: [Signal] = []
    private var phaseCount: UInt32 = 0
    private var logCount: UInt32 = 0
    private var error: WorkflowScriptRuntimeError?

    init(limits: WorkflowRunLimitsV1) { self.limits = limits }

    func recordPhase(_ value: String) { record(.phase(value)) }
    func recordLog(_ value: String) { record(.log(value)) }

    func drain() throws -> [Signal] {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        let result = signals
        signals.removeAll(keepingCapacity: true)
        return result
    }

    private func record(_ signal: Signal) {
        lock.lock(); defer { lock.unlock() }
        guard error == nil else { return }
        switch signal {
        case .phase(let value):
            phaseCount += 1
            guard phaseCount <= limits.maximumPhaseEntries, value.utf8.count <= 2_048 else {
                error = .invalidResult("workflow phase log exceeds its limit")
                return
            }
        case .log(let value):
            logCount += 1
            guard logCount <= limits.maximumLogLines, value.utf8.count <= 16_384 else {
                error = .invalidResult("workflow log exceeds its limit")
                return
            }
        }
        signals.append(signal)
    }
}
