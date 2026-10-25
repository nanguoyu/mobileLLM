// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Typed subagent admission failures.
public enum SubagentSpawnError: Error, Hashable, Sendable {
    case parentUnavailable
    case parentTerminal
    case ceilingNotStrictlyAttenuated
    case budgetNotAttenuated(BudgetDimension)
    case resultUnavailable
    case invalidResult
    case reconciliationRequired(AgentFailure)
}

/// Spawns and collects durable child runs (spec §22). Children inherit only a strict subset of the
/// parent ceiling, carry independent budgets, return structured results and artifacts, and can never
/// approve their own external access.
public protocol SubagentSpawning: Sendable {
    func pendingSessionInputs(runIDs: [AgentRunID]) async throws -> AgentSessionPendingInputs
    func withSessionInputBarrier(runIDs: [AgentRunID],
                                 operation: @Sendable () async throws -> JSONValue) async throws -> JSONValue
    func webObservations(_ handleID: AgentExecutionHandleID) async throws -> [WorkflowWebObservation]
    /// Read a committed terminal result without starting or resuming a child.
    func terminalResult(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult?
    /// Submits one child run under a reserved parent identity and returns its execution handle.
    func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID
    /// The workflow has already reserved this activation's share of its cumulative budget.
    func spawn(_ request: SubagentSpawnRequest, continuing seedRunID: AgentRunID,
               senderRunID: AgentRunID) async throws -> AgentExecutionHandleID
    /// Waits for the child's durable terminal result.
    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult
    /// Reports durable and streamed activity while collecting, for a caller's inactivity deadline.
    func collect(_ handleID: AgentExecutionHandleID,
                 onProgress: @escaping @Sendable () async -> Void) async throws -> SubagentResult
    /// Idempotently cancels one durable child. Used for explicit workflow stop and un-awaited calls.
    func cancel(_ handleID: AgentExecutionHandleID, runID: AgentRunID) async throws
    /// Resolves the exact uncertain child invocation through its normal durable command path.
    func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision
    ) async throws
    /// Generation-disambiguated reconciliation for a child that may cross more than one uncertain
    /// operation during its lifetime. Generations are durable workflow facts and start at one.
    func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision,
        generation: UInt32
    ) async throws
}

public extension SubagentSpawning {
    func pendingSessionInputs(runIDs: [AgentRunID]) async throws -> AgentSessionPendingInputs { AgentSessionPendingInputs() }
    func withSessionInputBarrier(runIDs: [AgentRunID],
                                 operation: @Sendable () async throws -> JSONValue) async throws -> JSONValue { try await operation() }
    func spawn(_ request: SubagentSpawnRequest, continuing seedRunID: AgentRunID,
               senderRunID: AgentRunID) async throws -> AgentExecutionHandleID {
        throw AgentSessionError.unavailable
    }
    func webObservations(_: AgentExecutionHandleID) async throws -> [WorkflowWebObservation] { [] }
    func terminalResult(_: AgentExecutionHandleID) async throws -> SubagentResult? { nil }
    func collect(_ handleID: AgentExecutionHandleID,
                 onProgress: @escaping @Sendable () async -> Void) async throws -> SubagentResult {
        try await collect(handleID)
    }

    /// Zero or nil disables the inactivity deadline. Cancellation still settles the durable child
    /// through the workflow engine before the workflow can report a terminal failure.
    func collect(_ handleID: AgentExecutionHandleID, stallMilliseconds: UInt64?) async throws -> SubagentResult {
        guard let milliseconds = stallMilliseconds, milliseconds > 0 else { return try await collect(handleID) }
        guard milliseconds <= 1_800_000 else { throw SubagentSpawnError.invalidResult }
        let deadline = SubagentProgressDeadline(milliseconds: milliseconds)
        return try await withThrowingTaskGroup(of: SubagentResult.self) { group in
            group.addTask { try await collect(handleID, onProgress: { await deadline.markProgress() }) }
            group.addTask { try await deadline.waitForStall() }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SubagentSpawnError.resultUnavailable }
            return result
        }
    }

    func cancel(_: AgentExecutionHandleID, runID _: AgentRunID) async throws {
        throw SubagentSpawnError.resultUnavailable
    }

    func reconcile(
        _: AgentExecutionHandleID,
        runID _: AgentRunID,
        decision _: AgentReconciliationDecision
    ) async throws {
        throw SubagentSpawnError.resultUnavailable
    }

    func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision,
        generation _: UInt32
    ) async throws {
        try await reconcile(handleID, runID: runID, decision: decision)
    }
}

/// Production spawner over a shared `AgentExecutor` and the run journal.
public struct DurableSubagentSpawner: SubagentSpawning, Sendable {
    private let executor: any AgentExecutor
    private let repository: any RuntimeRepository

    public init(
        executor: any AgentExecutor,
        repository: any RuntimeRepository
    ) {
        self.executor = executor
        self.repository = repository
    }

    public func pendingSessionInputs(runIDs: [AgentRunID]) async throws -> AgentSessionPendingInputs {
        guard let executor = executor as? DurableAgentExecutor else { throw AgentSessionError.unavailable }
        return try await executor.controller.pendingSessionInputs(runIDs: runIDs)
    }

    public func withSessionInputBarrier(runIDs: [AgentRunID],
                                        operation: @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        guard let executor = executor as? DurableAgentExecutor else { throw AgentSessionError.unavailable }
        return try await executor.controller.withSessionInputBarrier(runIDs: runIDs, operation: operation)
    }

    public func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID {
        try await spawn(request, continuation: nil)
    }

    public func spawn(_ request: SubagentSpawnRequest, continuing seedRunID: AgentRunID,
                      senderRunID: AgentRunID) async throws -> AgentExecutionHandleID {
        try await spawn(request, continuation: (seedRunID, senderRunID))
    }

    private func spawn(_ request: SubagentSpawnRequest,
                       continuation: (AgentRunID, AgentRunID)?) async throws -> AgentExecutionHandleID {
        guard let parentFacts = try await repository.loadRunFacts(for: request.parentRunID) else {
            throw SubagentSpawnError.parentUnavailable
        }
        // Workflow roots are app-orchestrated anchors: their ceiling is frozen at submission and
        // children inherit a strict subset of it even after the placeholder root answers. Parent
        // agents must stay alive; only `.workflow` provenance may anchor on a terminal parent.
        guard !parentFacts.projection.isTerminal || request.source == .workflow else {
            throw SubagentSpawnError.parentTerminal
        }
        guard let parentPayload = parentFacts.submission?.request.payload else {
            throw SubagentSpawnError.parentUnavailable
        }
        // Strict ceiling attenuation against the LIVE parent ceiling, never the caller's word.
        do {
            if parentPayload.capabilityCeiling.authority == .empty {
                // Empty is the irreducible least-authority scope; pure children cannot remove an
                // authority element that does not exist.
                guard request.capabilityCeiling.authority == .empty else {
                    throw SubagentSpawnError.ceilingNotStrictlyAttenuated
                }
            } else {
                _ = try parentPayload.capabilityCeiling.attenuating(
                    to: request.capabilityCeiling.authority,
                    requireStrict: true
                )
            }
        } catch {
            throw SubagentSpawnError.ceilingNotStrictlyAttenuated
        }
        try Self.validateBudgetAttenuation(
            child: request.budget,
            parent: parentPayload.budget
        )
        let childRequest = try AgentRequest(
            id: SubagentStableID.request(
                parentRunID: request.parentRunID,
                requestingStepID: request.requestingStepID,
                childRunID: request.childRunID
            ),
            runID: request.childRunID,
            conversationID: parentPayload.conversationID,
            userTurnID: parentPayload.userTurnID,
            parent: ParentAgentContext(
                runID: request.parentRunID,
                requestingStepID: request.requestingStepID,
                capabilityCeiling: parentPayload.capabilityCeiling
            ),
            role: request.role,
            instruction: request.instruction,
            outputRequirement: request.outputRequirement,
            modelPolicy: request.modelPolicy,
            capabilityCeiling: request.capabilityCeiling,
            budget: request.budget,
            contextReferences: request.contextReferences,
            artifactReferences: request.artifactReferences,
            sandboxRequirement: request.sandboxRequirement,
            labels: request.labels,
            provenance: AgentRequestProvenance(
                source: request.source,
                sourceMessageID: parentPayload.provenance.sourceMessageID,
                parentRequestID: parentPayload.id,
                evidenceDigests: request.evidenceDigests
            ),
            approvalMode: request.approvalMode
        )
        let command = SubagentStableID.command(parentRunID: request.parentRunID, childRunID: request.childRunID)
        if let (seed, sender) = continuation {
            guard request.source == .workflow, let durable = executor as? DurableAgentExecutor else {
                throw AgentSessionError.unavailable
            }
            return try await durable.controller.submitWorkflowActivation(childRequest, commandID: command,
                                                                         seedRunID: seed, senderRunID: sender)
        }
        return try await executor.submit(childRequest, commandID: command)
    }

    public func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        let handle = try await executor.attach(to: handleID)
        return try await collectHandle(handle, onProgress: nil)
    }

    public func terminalResult(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult? {
        let handle = try await executor.attach(to: handleID)
        return try await handle.result().map(Self.normalize)
    }

    public func webObservations(_ handleID: AgentExecutionHandleID) async throws -> [WorkflowWebObservation] {
        guard let snapshot = try await repository.loadRunSnapshot(for: handleID) else { throw SubagentSpawnError.resultUnavailable }
        let history = try ExecutionHistory(events: snapshot.events, projection: snapshot.facts.projection)
        let ids = try [AgentToolLogicalID(providerID: "builtin", name: "web_search"),
                       AgentToolLogicalID(providerID: "builtin", name: "fetch_webpage")]
        return try history.toolOutcomes.sorted { $0.value.0.sequence < $1.value.0.sequence }.flatMap { id, recorded -> [WorkflowWebObservation] in
            guard let plan = history.toolIntents[id]?.1.plan, plan.kind == .tool,
                  plan.effects == [.networkRead], plan.idempotency == .pureRead,
                  let toolID = ids.first(where: { $0.description == plan.subjectID }),
                  let argumentsPayload = plan.canonicalArguments else { return [] }
            let arguments = try AgentWireDecoder.decode(JSONValue.self, from: argumentsPayload.value.data, limits: .inlineValue)
            let url: String?
            if case .object(let object) = arguments, case .string(let value)? = object["url"] { url = value }
            else { url = nil }
            let status: String
            let text: String
            switch recorded.1 {
            case .completed(let values):
                status = "completed"
                if toolID.name == "web_search" {
                    for value in values {
                        if case .structured(let result) = value,
                           let sources = try WorkflowSearchEvidence.observations(result, invocationID: id.description, toolID: toolID) {
                            return sources
                        }
                    }
                }
                text = values.compactMap { value -> String? in
                    guard case .text(let result) = value else { return nil }
                    return result.value
                }.joined(separator: "\n")
            case .failed(let failure): status = "failed"; text = failure.safeMessage
            case .uncertain(let failure): status = "uncertain"; text = failure.safeMessage
            }
            return [WorkflowWebObservation(invocationID: id.description, toolID: toolID, requestedURL: url, status: status, text: text)]
        }
    }

    public func collect(_ handleID: AgentExecutionHandleID,
                        onProgress: @escaping @Sendable () async -> Void) async throws -> SubagentResult {
        let handle = try await executor.attach(to: handleID)
        let stream = await handle.ephemeralEvents()
        let observer = Task {
            do { for try await _ in stream { await onProgress() } } catch { }
        }
        defer { observer.cancel() }
        return try await collectHandle(handle, onProgress: onProgress)
    }

    private func collectHandle(_ handle: any AgentExecutionHandle,
                               onProgress: (@Sendable () async -> Void)?) async throws -> SubagentResult {
        var cursor: AgentEventCursor?
        // A dropped/out-of-order notification must not turn an accepted cancellation into an
        // uncertain external effect. Reattach read-only from the last trusted durable cursor.
        // Every reattachment first validates a fresh snapshot; corrupt journal facts still fail.
        for attachment in 0 ..< 3 {
            try Task.checkCancellation()
            if let result = try await handle.result() { return try Self.normalize(result) }
            let initialStatus = try await handle.status()
            try Self.rejectReconciliationWait(initialStatus)
            do {
                for try await envelope in handle.events(after: cursor) {
                    cursor = envelope.payload.cursor
                    await onProgress?()
                    if case .statusChanged(let status) = envelope.payload.event,
                       status.stateVersion >= initialStatus.stateVersion {
                        try Self.rejectReconciliationWait(status)
                    }
                    guard case .terminal = envelope.payload.event else { continue }
                    guard let result = try await handle.result() else { throw SubagentSpawnError.resultUnavailable }
                    return try Self.normalize(result)
                }
            } catch {
                if let result = try await handle.result() { return try Self.normalize(result) }
                guard error as? AgentExecutionError == .invalidRecoveryBoundary, attachment < 2 else { throw error }
            }
        }
        if let result = try await handle.result() { return try Self.normalize(result) }
        throw SubagentSpawnError.resultUnavailable
    }

    public func cancel(_ handleID: AgentExecutionHandleID, runID: AgentRunID) async throws {
        let handle = try await executor.attach(to: handleID)
        // A model/tool callback can advance the run between the status read and command CAS. A
        // stale receipt proves that no cancellation was applied, so retry against the receipt's
        // newer durable version instead of incorrectly escalating a harmless race to workflow
        // reconciliation. The expected version is part of the stable command identity: every
        // retry remains idempotent across a crash, while a completed stale command can never poison
        // a later cancellation attempt for the same child.
        for _ in 0 ..< 16 {
            let status = try await handle.status()
            guard !status.state.isTerminal else { return }
            let commandID = SubagentStableID.cancelCommand(
                runID: runID,
                handleID: handleID,
                expectedRunStateVersion: status.stateVersion
            )
            let envelope: AgentCommandEnvelope
            if let existing = try await repository.loadCommand(commandID) {
                guard existing.runID == runID,
                      existing.envelope.payload.action == .cancel,
                      existing.envelope.payload.expectedRunStateVersion == status.stateVersion
                else { throw SubagentSpawnError.invalidResult }
                if existing.state == .completed {
                    guard let receipt = existing.receipt?.payload else {
                        throw SubagentSpawnError.invalidResult
                    }
                    switch receipt.disposition {
                    case .accepted:
                        return
                    case .stale:
                        continue
                    case .rejected:
                        throw SubagentSpawnError.resultUnavailable
                    }
                }
                envelope = existing.envelope
            } else {
                envelope = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: commandID,
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .cancel,
                issuedAt: try AgentTimestamp(Date())
                ))
            }
            let receipt = try await handle.send(envelope)
            switch receipt.disposition {
            case .accepted:
                return
            case .stale:
                continue
            case .rejected:
                throw SubagentSpawnError.resultUnavailable
            }
        }
        throw SubagentSpawnError.resultUnavailable
    }

    public func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision
    ) async throws {
        try await reconcile(handleID, runID: runID, decision: decision, generation: 1)
    }

    public func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision,
        generation: UInt32
    ) async throws {
        guard generation > 0 else { throw SubagentSpawnError.invalidResult }
        let handle = try await executor.attach(to: handleID)
        let commandID = SubagentStableID.reconcileCommand(
            runID: runID,
            handleID: handleID,
            decision: decision,
            generation: generation
        )
        let envelope: AgentCommandEnvelope
        if let existing = try await repository.loadCommand(commandID) {
            guard existing.runID == runID,
                  case .reconcile(_, let recordedDecision) = existing.envelope.payload.action,
                  recordedDecision == decision
            else { throw SubagentSpawnError.invalidResult }
            if existing.state == .completed {
                guard existing.receipt?.payload.disposition == .accepted else {
                    throw SubagentSpawnError.resultUnavailable
                }
                return
            }
            // Replay the byte-identical admitted command. Reconstructing it with a new timestamp
            // or state version would conflict with the stable command identity after a crash.
            envelope = existing.envelope
        } else {
            let status = try await handle.status()
            guard status.state == .waitingForReconciliation,
                  case .reconciliation(let invocationID) = status.blockingReason
            else { throw SubagentSpawnError.resultUnavailable }
            envelope = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: commandID,
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .reconcile(invocationID: invocationID, decision: decision),
                issuedAt: try AgentTimestamp(Date())
            ))
        }
        let receipt = try await handle.send(envelope)
        guard receipt.disposition == .accepted else {
            throw SubagentSpawnError.resultUnavailable
        }
    }

    private static func rejectReconciliationWait(_ status: AgentRunStatus) throws {
        guard status.state == .waitingForReconciliation else { return }
        guard let failure = status.failure else { throw SubagentSpawnError.invalidResult }
        throw SubagentSpawnError.reconciliationRequired(failure)
    }

    private static func normalize(_ result: AgentResult) throws -> SubagentResult {
        let outcome: SubagentOutcome
        switch result.status.state {
        case .completed:
            guard let answer = result.answer else { throw SubagentSpawnError.invalidResult }
            outcome = .completed(answer: answer, usage: result.usage)
        case .failed:
            guard let failure = result.status.failure else {
                throw SubagentSpawnError.invalidResult
            }
            outcome = .failed(failure: failure, usage: result.usage)
        case .cancelled:
            outcome = .cancelled
        default:
            throw SubagentSpawnError.invalidResult
        }
        return SubagentResult(
            runID: result.runID,
            handleID: result.executionHandleID,
            outcome: outcome,
            terminalUsage: result.status.state == .cancelled ? result.usage : nil
        )
    }

    private static func validateBudgetAttenuation(
        child: AgentBudget,
        parent: AgentBudget
    ) throws {
        var strictlySmaller = false
        for dimension in BudgetDimension.allCases {
            let childValue = child.limits[dimension]
            let parentValue = parent.limits[dimension]
            guard childValue <= parentValue else {
                throw SubagentSpawnError.budgetNotAttenuated(dimension)
            }
            if childValue < parentValue { strictlySmaller = true }
        }
        guard child.maximumThermalState <= parent.maximumThermalState,
              child.memoryPressureResponse == parent.memoryPressureResponse
        else { throw SubagentSpawnError.budgetNotAttenuated(.activeMilliseconds) }
        if child.maximumThermalState < parent.maximumThermalState { strictlySmaller = true }
        guard strictlySmaller else {
            throw SubagentSpawnError.budgetNotAttenuated(.activeMilliseconds)
        }
    }
}

/// Deterministic child identities so relaunch can reconstruct the same run tree.
enum SubagentStableID {
    static func request(
        parentRunID: AgentRunID,
        requestingStepID: AgentStepID,
        childRunID: AgentRunID
    ) -> AgentRequestID {
        AgentRequestID(rawValue: uuid(
            domain: "subagent-request.v1",
            components: [
                parentRunID.description,
                requestingStepID.description,
                childRunID.description,
            ]
        ))
    }

    static func command(parentRunID: AgentRunID, childRunID: AgentRunID) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "subagent-command.v1",
            components: [parentRunID.description, childRunID.description]
        ))
    }

    static func cancelCommand(
        runID: AgentRunID,
        handleID: AgentExecutionHandleID,
        expectedRunStateVersion: UInt64
    ) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "subagent-cancel-command.v2",
            components: [
                runID.description,
                handleID.description,
                String(expectedRunStateVersion),
            ]
        ))
    }

    static func reconcileCommand(
        runID: AgentRunID,
        handleID: AgentExecutionHandleID,
        decision: AgentReconciliationDecision,
        generation: UInt32
    ) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "subagent-reconcile-command.v1",
            components: [
                runID.description,
                handleID.description,
                decision.rawValue,
                String(generation),
            ]
        ))
    }

    static func childRun(workflowID: UUID, phase: UInt64, child: Int) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-child.v1",
            components: [workflowID.uuidString, String(phase), String(child)]
        ))
    }

    static func rootRun(workflowID: UUID) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-root.v1",
            components: [workflowID.uuidString]
        ))
    }

    static func rootCommand(workflowID: UUID) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "workflow-root-command.v1",
            components: [workflowID.uuidString]
        ))
    }

    private static func uuid(domain: String, components: [String]) -> UUID {
        let digest = StableDigest.fingerprint(
            domain: "mobilellm.\(domain)",
            components: components.map { Data($0.utf8) }
        )
        let bytes = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            let start = digest.rawValue.index(digest.rawValue.startIndex, offsetBy: index)
            let end = digest.rawValue.index(start, offsetBy: 2)
            return UInt8(digest.rawValue[start ..< end], radix: 16)!
        }
        var value = bytes
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}

/// Public stable identities for workflow roots and children (spec §23): relaunch can reconstruct
/// the exact run tree from the workflow id alone.
public enum WorkflowIdentity {
    public static func rootRun(workflowID: UUID) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-root.v1",
            components: [workflowID.uuidString]
        ))
    }

    public static func rootCommand(workflowID: UUID) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "workflow-root-command.v1",
            components: [workflowID.uuidString]
        ))
    }

    public static func rootStep(workflowID: UUID) -> AgentStepID {
        AgentStepID(rawValue: uuid(
            domain: "workflow-root-step.v1",
            components: [workflowID.uuidString]
        ))
    }

    public static func childRun(workflowID: UUID, phase: UInt64, child: Int) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-child.v1",
            components: [workflowID.uuidString, String(phase), String(child)]
        ))
    }

    private static func uuid(domain: String, components: [String]) -> UUID {
        let digest = StableDigest.fingerprint(
            domain: "mobilellm.\(domain)",
            components: components.map { Data($0.utf8) }
        )
        let bytes = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            let start = digest.rawValue.index(digest.rawValue.startIndex, offsetBy: index)
            let end = digest.rawValue.index(start, offsetBy: 2)
            return UInt8(digest.rawValue[start ..< end], radix: 16)!
        }
        var value = bytes
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}
