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
        let preparation = try await spawner.preparationUsage(runID: snapshot.initiatingRunID)
        let preparationEvent = try WorkflowRunEventV1(eventID: WorkflowEventID(), runID: snapshot.runID,
            sequence: 2, timestamp: timestamp, previousDigest: created.recordDigest, kind: .preparationUsageCommitted(preparation))
        var projection = try await journal.append(try WorkflowEventAppendRequestV1(
            runID: snapshot.runID,
            expectedSequence: 0,
            expectedDigest: nil,
            events: [created, preparationEvent]
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
        let saved = try await requiredProjection(runID)
        if saved.state == .paused, var graph = saved.taskGraph,
           graph.state != .active, graph.state != .completed, graph.state != .cancelled,
           let index = saved.collaborationReceipts.last?.index {
            try graph.setGoalState(.active, reason: "Explicitly resumed")
            _ = try await append([.goalResumed(pauseIndex: index, graph: graph)], to: saved)
        }
        try await start(runID: runID)
    }

    /// User amendments are separate immutable facts. Reading a goal never invokes this method.
    public func amendGoal(runID: WorkflowRunID, messageID: MessageID, text: String) async throws {
        guard !dataEraseSuspended else { throw WorkflowScriptRuntimeError.cancelled }
        let amendment = WorkflowGoalAmendment(id: messageID, text: text, acceptedAt: try await clock.now())
        if let current = active[runID] {
            try await current.session.amendGoal(amendment)
        } else {
            let saved = try await requiredProjection(runID)
            if let prior = saved.taskGraph?.amendments.first(where: { $0.id == messageID }) {
                guard prior.text == text else { throw WorkflowTaskGraphError.stale }
                try await spawner.deliverGoalAmendment(prior, goalID: runID, conversationID: saved.launch.conversationID,
                    runIDs: prior.targetRunIDs ?? [saved.launch.initiatingRunID])
                return
            }
            let stored = WorkflowGoalAmendment(id: messageID, text: text, acceptedAt: amendment.acceptedAt,
                targetRunIDs: goalAmendmentRecipients(saved))
            _ = try await append([.goalAmended(stored)], to: saved)
            try await spawner.deliverGoalAmendment(stored, goalID: runID, conversationID: saved.launch.conversationID,
                runIDs: stored.targetRunIDs ?? [])
        }
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
    private var evidenceCache: (sequence: UInt64, query: String?, value: JSONValue)?
    /// Only observations reached by this execution prefix may enter prompts. A recovered journal
    /// can contain later settled calls, which must not leak backward and change replay identities.
    private var evidenceVisibleCalls: Set<WorkflowAgentCallID> = []
    private var detachedCalls: [UInt32: WorkflowAgentCallID] = [:]
    private var journalWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var nextWaitIndex: UInt32 = 1

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
                _ = try await append([.stateChanged(
                    from: projection.state, to: .running, reason: "execution-started"
                )])
            }
            try await deliverGoalAmendments()
            let host = makeHost(depth: 0)
            let result = try await runtime.execute(
                script,
                args: projection.launch.args,
                limits: projection.launch.limits,
                requirement: projection.launch.runtimeRequirement,
                host: host
            )
            try await flushSignals()
            guard projection.state != .waitingForReconciliation else {
                throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
            }
            if stopped {
                try await terminateAsCancelled()
                throw WorkflowScriptRuntimeError.cancelled
            }
            let reference = try await valueStore.store(result, runID: projection.runID)
            _ = try await append([
                .outputCommitted(reference),
                .stateChanged(from: projection.state, to: .completed, reason: nil),
            ])
            return result
        } catch let runtimeError as WorkflowScriptRuntimeError where runtimeError == .cancelled {
            if projection.state == .pausing {
                _ = try await append([
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
                _ = try await append([
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
                _ = try await append([
                    .failureCommitted(childFailure.failure.safeMessage),
                    .stateChanged(from: projection.state, to: .failed, reason: childFailure.failure.code),
                ])
            }
            throw childFailure
        } catch {
            if projection.state == .waitingForReconciliation { throw error }
            if let goal = projection.taskGraph, [.blocked, .budgetExhausted, .paused].contains(goal.state),
               projection.submittedHandles.keys.allSatisfy({ projection.outcomes[$0] != nil }),
               !projection.isTerminal {
                _ = try await append([.stateChanged(from: projection.state, to: .paused, reason: goal.reason)])
                throw error
            }
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
                _ = try await append([
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
                guard depth == 0 || !invocation.deliversOnWait else { throw WorkflowScriptRuntimeError.unsupportedRequirement }
                let global = try await router.map(invocation)
                return try await self.invokeAgent(global, detachedHandle: invocation.deliversOnWait ? invocation.sequence : nil)
            },
            callSavedWorkflow: savedCall,
            phase: { [signals] in signals.recordPhase($0) },
            log: { [signals] in signals.recordLog($0) },
            budget: { [budgetCounter] in budgetCounter.snapshot() },
            settledBudget: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.recordedBudget()
            },
            webEvidence: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.recordedWebEvidence()
            },
            queryWebEvidence: { [weak self] query in
                guard let self else { throw CancellationError() }
                return try await self.recordedWebEvidence(query: query)
            },
            waitAny: { [weak self] index, ordinals in
                guard let self, depth == 0 else { throw WorkflowScriptRuntimeError.unsupportedRequirement }
                return try await self.waitAny(index: index, ordinals: ordinals)
            },
            collaborate: { [weak self] index, command in
                guard let self, depth == 0 else { throw WorkflowScriptRuntimeError.unsupportedRequirement }
                return try await self.collaborate(index: index, command: command)
            }
        )
    }

    /// Waiting occupies no dispatch permit, model request, or residency lease. Journal changes
    /// wake the caller; the persisted receipt fixes the chosen result before it enters a prompt.
    private func waitAny(index: UInt32, ordinals: [UInt32]) async throws -> JSONValue {
        guard index == nextWaitIndex, !ordinals.isEmpty,
              ordinals.count <= projection.launch.limits.maximumAgentCalls,
              Set(ordinals).count == ordinals.count else { throw DynamicWorkflowEngineError.invocationOrderMismatch }
        nextWaitIndex += 1
        while true {
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            let candidates = ordinals.compactMap { detachedCalls[$0] }
            if candidates.count == ordinals.count, candidates.allSatisfy({ id in projection.calls.contains { $0.callID == id } }) {
                let selected: WorkflowAgentCallID?
                if let saved = projection.waits.first(where: { $0.index == index }) {
                    guard saved.candidates == candidates else { throw DynamicWorkflowEngineError.invocationOrderMismatch }
                    selected = saved.selected
                } else {
                    selected = candidates.filter { projection.outcomes[$0] != nil }.min {
                        projection.settledSequences[$0, default: .max] < projection.settledSequences[$1, default: .max]
                    }
                    if let selected {
                        _ = try await append([.waitSelected(try WorkflowWaitSelection(
                            index: index, candidates: candidates, selected: selected))])
                    }
                }
                if let selected, let outcome = projection.outcomes[selected],
                   let ordinal = ordinals.first(where: { detachedCalls[$0] == selected }) {
                    evidenceVisibleCalls.insert(selected)
                    evidenceCache = nil
                    var result: [String: JSONValue] = ["handle": .unsignedInteger(UInt64(ordinal))]
                    switch outcome {
                    case .completed(let reference, _):
                        result["status"] = .string("completed")
                        result["value"] = try JSONDecoder().decode(JSONValue.self, from: await valueStore.load(reference).data)
                    case .failed(let failure, _):
                        result["status"] = .string("failed"); result["error"] = .string(failure.safeMessage)
                        if projection.calls.first(where: { $0.callID == selected })?.options.task?.goalAmendmentCount != nil {
                            result["code"] = .string(failure.code)
                        }
                    case .unavailable(let reason, _):
                        result["status"] = .string("unavailable"); result["error"] = .string(reason)
                    case .stopped:
                        result["status"] = .string("cancelled")
                    }
                    return .object(result)
                }
            }
            try await awaitJournalChange()
        }
    }

    private func awaitJournalChange() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                journalWaiters[id] = continuation
                if Task.isCancelled { cancelJournalWait(id) }
            }
        } onCancel: {
            Task { await self.cancelJournalWait(id) }
        }
    }

    private func cancelJournalWait(_ id: UUID) {
        journalWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func wakeJournalWaiters() {
        let waiting = Array(journalWaiters.values)
        journalWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func amendGoal(_ amendment: WorkflowGoalAmendment) async throws {
        let stored = try await appendMutex.run { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.acceptGoalAmendment(amendment)
        }
        try await spawner.deliverGoalAmendment(stored, goalID: projection.runID, conversationID: projection.launch.conversationID,
            runIDs: stored.targetRunIDs ?? [projection.launch.initiatingRunID])
    }

    private func acceptGoalAmendment(_ amendment: WorkflowGoalAmendment) async throws -> WorkflowGoalAmendment {
        if let prior = projection.taskGraph?.amendments.first(where: { $0.id == amendment.id }) {
            guard prior.text == amendment.text else { throw WorkflowTaskGraphError.stale }
            return prior
        }
        let stored = WorkflowGoalAmendment(id: amendment.id, text: amendment.text, acceptedAt: amendment.acceptedAt,
            targetRunIDs: goalAmendmentRecipients(projection))
        _ = try await performAppendAndInstall([.goalAmended(stored)])
        return stored
    }

    private func deliverGoalAmendments(only runID: AgentRunID? = nil) async throws {
        for amendment in projection.taskGraph?.amendments ?? [] {
            let targets = amendment.targetRunIDs ?? [projection.launch.initiatingRunID]
            let selected = runID.map { id in targets.filter { $0 == id } } ?? targets
            try await spawner.deliverGoalAmendment(amendment, goalID: projection.runID,
                conversationID: projection.launch.conversationID, runIDs: selected)
        }
    }

    private func collaborate(index: UInt32, command: CanonicalJSON) async throws -> JSONValue {
        guard command.data.count <= 262_144, index > 0, index <= 256 else { throw WorkflowTaskGraphError.invalid }
        if let receipt = projection.collaborationReceipts.first(where: { $0.index == index }) {
            guard receipt.commandDigest == command.fingerprint else { throw DynamicWorkflowEngineError.invocationOrderMismatch }
            return try collaborationPacket(receipt, resumed: projection.goalResumptions[index])
        }
        let decoded = try JSONDecoder().decode(WorkflowCollaborationCommand.self, from: command.data)
        if decoded.action == "admitted" {
            guard let handles = decoded.handles, !handles.isEmpty else { throw WorkflowTaskGraphError.invalid }
            while !handles.allSatisfy({ handle in
                guard let id = detachedCalls[handle] else { return false }
                return projection.calls.contains { $0.callID == id }
            }) {
                try Task.checkCancellation()
                try await awaitJournalChange()
            }
        }
        if decoded.action == "deliver" {
            try await deliverGoalAmendments()
            let runIDs = [projection.launch.initiatingRunID] + projection.calls.map(\.childRunID)
            return try await spawner.withSessionInputBarrier(runIDs: runIDs) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.commitCollaboration(index: index, command: command, decoded: decoded)
            }
        }
        return try await commitCollaboration(index: index, command: command, decoded: decoded)
    }

    private func commitCollaboration(index: UInt32, command: CanonicalJSON,
                                     decoded: WorkflowCollaborationCommand) async throws -> JSONValue {
        try await appendMutex.run { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performCollaboration(index: index, command: command, decoded: decoded)
        }
    }

    private func performCollaboration(index: UInt32, command: CanonicalJSON,
                                      decoded: WorkflowCollaborationCommand) async throws -> JSONValue {
        guard index == projection.collaborationReceipts.count + 1 else { throw DynamicWorkflowEngineError.invocationOrderMismatch }
        var graph: WorkflowTaskGraph
        if let current = projection.taskGraph { graph = current }
        else {
            guard let args = projection.launch.args,
                  case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: args.data),
                  case .string(let objective)? = root["goal"] else { throw WorkflowTaskGraphError.invalid }
            graph = try WorkflowTaskGraph(objective: objective)
        }
        var feedback: String?
        var observation: JSONValue?
        let pendingInputs = try await spawner.pendingSessionInputs(runIDs: [projection.launch.initiatingRunID] + projection.calls.map(\.childRunID))
        do {
            switch decoded.action {
            case "snapshot", "admitted": break
            case "continueInbox":
                guard let revision = decoded.expectedRevision, let recipient = decoded.recipient,
                      recipient != "coordinator", !graph.tasks.contains(where: { $0.agent == recipient }),
                      let message = pendingInputs.messages.first(where: { message in
                          projection.calls.contains { $0.childRunID == message.seedRunID && $0.options.sessionKey == recipient }
                      }), let source = projection.calls.first(where: { $0.childRunID == message.seedRunID }) else {
                    throw WorkflowTaskGraphError.unavailableInput
                }
                // Reassignment changes task ownership, not the addressed agent's inbox. Give
                // that existing session a bounded follow-up without undoing the reassignment or
                // silently discarding messages. Its original profile/model remain the ceiling.
                let prior = graph.artifacts.last(where: { $0.callID == source.callID })
                try graph.update([WorkflowTaskUpdate(id: "inbox-" + message.id.description, expectedRevision: 0,
                    agent: recipient,
                    instruction: "Process your accepted pending messages for this goal. Your former assignment has been reassigned. Preserve the current ownership; do not redo that assignment unless a human explicitly requests it. Return any new evidence or correction, or acknowledge that an obsolete notice needs no further action. Your result reaches the coordinator automatically; do not send a redundant acknowledgement.",
                    maximumToolCalls: source.options.maximumToolCalls ?? 0, model: source.options.requestedModel,
                    artifactInputs: prior.map { [$0.id] } ?? [], profile: source.options.profile)], expectedRevision: revision)
            case "update":
                guard let revision = decoded.expectedRevision, let changes = decoded.tasks else { throw WorkflowTaskGraphError.invalid }
                try graph.update(changes, expectedRevision: revision)
            case "settle":
                guard let handle = decoded.handle, let id = detachedCalls[handle], evidenceVisibleCalls.contains(id),
                      let call = projection.calls.first(where: { $0.callID == id }), let outcome = projection.outcomes[id]
                else { throw WorkflowTaskGraphError.ownership }
                if case .failed(let failure, _) = outcome, failure.code == "workflow.task-admission" {
                    // The call never acquired this task. Return the current graph so dispatch can
                    // use the newer goal/task revision without inventing a failed execution.
                } else { try graph.settle(call: call, outcome: outcome) }
            case "read":
                guard let id = decoded.artifactID, let artifact = graph.artifacts.first(where: { $0.id == id }),
                      let offset = decoded.offset, offset >= 0, let length = decoded.length, (1...12_000).contains(length)
                else { throw WorkflowTaskGraphError.unavailableInput }
                let raw = try await valueStore.load(artifact.value)
                observation = .object(try WorkflowArtifactExcerpt.read(raw, id: id, offset: offset, length: length))
            case "deliver":
                guard decoded.expectedRevision == graph.revision else { throw WorkflowTaskGraphError.stale }
                guard pendingInputs.count == 0 else { throw AgentSessionError.pendingInput }
                guard projection.submittedHandles.keys.allSatisfy({ projection.outcomes[$0] != nil }),
                      projection.reconciliationCallID == nil else { throw WorkflowTaskGraphError.incomplete }
                try graph.setGoalState(.completed, reason: decoded.reason)
            case "pause":
                guard !graph.tasks.contains(where: { $0.state == .running }) else { throw WorkflowTaskGraphError.incomplete }
                let next: WorkflowGoalState = decoded.reasonCode == "budget" ? .budgetExhausted : .blocked
                try graph.setGoalState(next, reason: decoded.reason)
            default: throw WorkflowTaskGraphError.invalid
            }
        } catch let error as WorkflowTaskGraphError {
            feedback = error.localizedDescription
            // Graph methods are transactional; an invalid model command is feedback, not a
            // partial state change or an exception that discards successful sibling results.
        } catch AgentSessionError.pendingInput {
            feedback = "Accepted agent messages remain unincluded. Continue their addressed agents within the shared budget before delivering."
        }
        let sender = projection.calls.last(where: {
            $0.options.requestedAgentType == "workflow-supervisor" && evidenceVisibleCalls.contains($0.callID)
        })?.childRunID ?? projection.launch.initiatingRunID
        let receipt = WorkflowCollaborationReceipt(index: index, commandDigest: command.fingerprint,
            senderRunID: sender, graph: graph, feedback: feedback, observation: observation, pendingInputs: pendingInputs)
        _ = try await performAppendAndInstall([.collaborationRecorded(receipt)])
        return try collaborationPacket(receipt)
    }

    private func collaborationPacket(_ receipt: WorkflowCollaborationReceipt, resumed: WorkflowTaskGraph? = nil) throws -> JSONValue {
        let graph = resumed ?? receipt.graph
        let encoded = try JSONEncoder().encode(graph)
        guard case .object(var value) = try JSONDecoder().decode(JSONValue.self, from: encoded) else { throw WorkflowTaskGraphError.invalid }
        // Model-facing catalogs contain identities. Full protected payloads are retrieved only by
        // bounded read operations; they are never serialized into every coordination prompt.
        if case .array(let artifacts)? = value["artifacts"] {
            value["artifacts"] = .array(artifacts.map { artifact in
                guard case .object(var item) = artifact else { return artifact }
                item.removeValue(forKey: "value")
                return .object(item)
            })
        }
        let pending = receipt.pendingInputs ?? AgentSessionPendingInputs()
        let messages = pending.messages.map { item -> JSONValue in
            let recipient = item.seedRunID == projection.launch.initiatingRunID ? "coordinator"
                : projection.calls.first(where: { $0.childRunID == item.seedRunID })?.options.sessionKey ?? "unknown"
            return .object(["id": .string(item.id.description), "recipient": .string(recipient), "preview": .string(item.preview)])
        }
        return .object(["graph": .object(value), "ready": .array(graph.readyTasks.map { .string($0.id) }),
            "pendingInputs": .object(["count": .integer(Int64(pending.count)), "messages": .array(messages)]),
            "feedback": receipt.feedback.map(JSONValue.string) ?? .null, "observation": receipt.observation ?? .null])
    }

    private func recordedBudget() throws -> JSONValue {
        var consumed = projection.preparationUsage ?? .zero
        for call in projection.calls where evidenceVisibleCalls.contains(call.callID) {
            let usage: AgentUsage
            switch projection.outcomes[call.callID] {
            case .completed(_, let value), .unavailable(_, let value), .failed(_, let value), .stopped(let value): usage = value
            case nil: continue
            }
            consumed = try consumed.aggregating(usage)
        }
        func values(_ quantities: BudgetQuantities) -> JSONValue {
            .object([
                "toolCalls": .integer(Int64(clamping: quantities[.toolInvocations])),
                "modelAttempts": .integer(Int64(clamping: quantities[.modelAttempts])),
                "inputTokens": .integer(Int64(clamping: quantities[.inputTokens])),
                "outputTokens": .integer(Int64(clamping: quantities[.outputTokens])),
            ])
        }
        return .object(["limits": values(projection.launch.budget.limits), "consumed": values(consumed.quantities)])
    }

    private func recordedWebEvidence(query: String? = nil) async throws -> JSONValue {
        let sequence = projection.lastSequence
        if let cached = evidenceCache, cached.sequence == sequence, cached.query == query { return cached.value }
        var latest: [UInt32: WorkflowAgentCallV1] = [:]
        for call in projection.calls { latest[call.ordinal] = call }
        let calls = latest.values.sorted { $0.ordinal < $1.ordinal }
        var records: [(label: String, observation: WorkflowWebObservation)] = []
        for call in calls where evidenceVisibleCalls.contains(call.callID)
            && projection.outcomes[call.callID] != nil {
            try Task.checkCancellation()
            guard let handle = projection.submittedHandles[call.callID] else { continue }
            for observation in try await spawner.webObservations(handle) {
                records.append((call.options.label ?? "agent-\(call.ordinal)", observation))
            }
            if records.count >= WorkflowWebEvidence.maximumCandidates { break }
        }
        let value = try WorkflowWebEvidence.packet(records, matching: query)
        if projection.lastSequence == sequence { evidenceCache = (sequence, query, value) }
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
        _ = try await append([.stateChanged(from: .running, to: .pausing, reason: "user-pause")])
        try await scheduler.waitUntilPaused()
    }

    func resume() async throws {
        guard projection.state == .pausing || projection.state == .paused else {
            throw DynamicWorkflowEngineError.illegalRunState(projection.state)
        }
        await scheduler.resume()
        _ = try await append([.stateChanged(from: projection.state, to: .running, reason: "user-resume")])
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

    private func invokeAgent(_ invocation: WorkflowAgentInvocation, detachedHandle: UInt32? = nil) async throws -> WorkflowAgentBridgeResult {
        guard !stopped else { return .stopped }
        guard projection.state != .waitingForReconciliation else {
            throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
        }
        guard invocation.sequence <= projection.launch.limits.maximumAgentCalls else {
            throw DynamicWorkflowEngineError.agentCallLimitExceeded
        }
        try await order.wait(for: invocation.sequence)
        var visibleCallID: WorkflowAgentCallID?
        defer {
            if let callID = visibleCallID, !invocation.deliversOnWait, projection.outcomes[callID] != nil {
                evidenceVisibleCalls.insert(callID)
                evidenceCache = nil
            }
        }
        do {
            try await flushSignals()
            let decision = try await replay.next(prompt: invocation.prompt, options: invocation.options,
                                                 reuseSettledFailures: invocation.deliversOnWait)
            if invocation.deliversOnWait {
                let call: WorkflowAgentCallV1
                switch decision { case .reuse(let value, _), .continue(let value), .execute(let value): call = value }
                detachedCalls[detachedHandle ?? invocation.sequence] = call.callID
                wakeJournalWaiters()
            }
            switch decision {
            case .reuse(let call, let outcome):
                visibleCallID = call.callID
                await order.complete(invocation.sequence)
                return try await bridge(outcome)
            case .continue(let call):
                visibleCallID = call.callID
                await order.complete(invocation.sequence)
                return try await execute(call: call, prompt: invocation.prompt, prepared: true)
            case .execute(let call):
                visibleCallID = call.callID
                try await invalidateUnsettledSuffix(startingAt: call.ordinal)
                do {
                    _ = try await append([.agentCallPrepared(call)])
                } catch let error as WorkflowTaskGraphError {
                    let failure = try AgentFailure(code: "workflow.task-admission", classification: .permanent,
                        safeMessage: error.localizedDescription, retryAdvice: .never, externalEffect: .confirmedNone,
                        requiredUserAction: .none, redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1))
                    _ = try await append([.agentCallRejected(call: call, failure: failure)])
                    await order.complete(invocation.sequence)
                    throw WorkflowChildExecutionFailed(failure: failure)
                }
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
                _ = try await append([
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

        _ = try await append(stale.map {
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
        guard projection.state != .waitingForReconciliation else {
            throw WorkflowScriptRuntimeError.hostFailure("child reconciliation required")
        }
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
            let admitted: (request: SubagentSpawnRequest, admission: WorkflowBudgetAdmission)
            do {
                admitted = try await workflowBudget.admitAvailable(call: call) { remaining in
                    let request = try builder.makeRequest(
                        launch: launch, call: call, prompt: prompt, budgetLimit: remaining
                    )
                    try validator.validate(request, launch: launch, call: call)
                    return request
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No executor submission occurred. Persist the failed result so a caught
                // admission failure is replayable, rather than leaving a phantom prepared call.
                let classification: AgentFailureClassification
                if case AgentContractError.budgetExceeded = error { classification = .budgetRelated }
                else { classification = .permanent }
                let failure = try AgentFailure(code: "workflow.child-admission",
                    classification: classification, safeMessage: Self.sanitize((error as? LocalizedError)?.errorDescription ?? String(describing: error)),
                    retryAdvice: .never, externalEffect: .confirmedNone, requiredUserAction: .none,
                    redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1))
                _ = try await append([.agentCallSettled(callID: call.callID,
                    outcome: .failed(failure: failure, usage: .zero))])
                throw WorkflowChildExecutionFailed(failure: failure)
            }
            let request = admitted.request
            admission = admitted.admission
            do {
                let seed = call.options.sessionKey.flatMap { key in
                    projection.calls.first(where: {
                        $0.ordinal < call.ordinal && $0.options.sessionKey == key && projection.submittedHandles[$0.callID] != nil
                    })?.childRunID
                        ?? (key == "coordinator" && call.options.requestedAgentType == "workflow-supervisor" ? launch.initiatingRunID : nil)
                }
                if let seed {
                    // Identity is selected by the host from committed coordinator calls, never
                    // accepted as a sender name from model-produced options.
                    let sender = projection.calls.last(where: {
                        guard $0.ordinal < call.ordinal, $0.options.requestedAgentType == "workflow-supervisor",
                              projection.submittedHandles[$0.callID] != nil else { return false }
                        if case .completed = projection.outcomes[$0.callID] { return true }
                        return false
                    })?.childRunID ?? launch.initiatingRunID
                    handleID = try await spawner.spawn(request, continuing: seed, senderRunID: sender)
                } else {
                    handleID = try await spawner.spawn(request)
                }
            } catch {
                try? await workflowBudget.releaseUnsubmitted(admission)
                throw error
            }
            _ = try await append([.agentChildSubmitted(callID: call.callID, handleID: handleID)])
        }
        let result: SubagentResult
        do {
            do { try await deliverGoalAmendments(only: call.childRunID) }
            catch is CancellationError { throw CancellationError() }
            catch { signals.recordLog("Saved goal instructions await inbox delivery; completion will retry delivery.") }
            result = try await spawner.collect(handleID, stallMilliseconds: call.options.stallMilliseconds)
        } catch let timeout as SubagentStallTimeout {
            try await settleAfterCancellation(call: call, handleID: handleID, admission: admission)
            throw WorkflowScriptRuntimeError.hostFailure("Child agent made no observable progress for \(timeout.milliseconds) ms and was stopped.")
        } catch SubagentSpawnError.reconciliationRequired(let failure) {
            _ = try await append([
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
            _ = try await append([
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
                outcome: .failed(failure: failure, usage: result.usage),
                usage: result.usage
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
                // The accepted command may finish draining just after its observer closes. Give
                // that durable terminal commit a bounded grace period, without resubmitting work.
                if error as? SubagentSpawnError == .resultUnavailable
                    || error as? AgentExecutionError == .invalidRecoveryBoundary {
                    for delay in [50, 100, 200] {
                        try await Task.sleep(for: .milliseconds(delay))
                        if let terminal = try await spawner.terminalResult(handleID) { return terminal }
                    }
                }
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
            _ = try await append([
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
        wakeJournalWaiters()
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
        _ = try await append(kinds)
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
        wakeJournalWaiters()
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
        _ = try await append([
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
            options: invocation.options,
            deliversOnWait: invocation.deliversOnWait
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

private struct WorkflowCollaborationCommand: Decodable, Sendable {
    let action: String
    let expectedRevision: UInt64?
    let tasks: [WorkflowTaskUpdate]?
    let handles: [UInt32]?
    let handle: UInt32?
    let artifactID: String?
    let offset: Int?
    let length: Int?
    let reason: String?
    let reasonCode: String?
    let recipient: String?
}

private func goalAmendmentRecipients(_ projection: WorkflowRunProjectionV1) -> [AgentRunID] {
    let active = projection.calls.filter { projection.outcomes[$0.callID] == nil }.map(\.childRunID)
    return Array(Set([projection.launch.initiatingRunID] + active)).sorted { $0.description < $1.description }
}
